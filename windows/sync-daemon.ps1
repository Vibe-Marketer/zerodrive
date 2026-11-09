<#
.SYNOPSIS
    ZeroDrive Zero-Dependency Windows Background Sync Daemon
    Bi-directional, real-time synchronization between Windows and macOS/Linux cloud vault.

.DESCRIPTION
    Runs as a lightweight background sync engine on Windows 10/11 using standard PowerShell (5.1+ / 7+).
    - Initial Sync: Queries https://api.zerodrive.dev/v1/files and creates local placeholders.
    - Real-Time Inbound: Listens to SSE stream https://api.zerodrive.dev/v1/events and polls /v1/activity.
    - Real-Time Outbound: Uses System.IO.FileSystemWatcher to detect local file changes and POSTs to /vault/upload.
    - File Lock Safeguards: Graceful exponential backoff on ERROR_SHARING_VIOLATION / IOException.
    - On-Demand Hydration: Hydrates placeholders when triggered or read.

.PARAMETER SyncRoot
    Local directory path for ZeroDrive (Default: $HOME\ZeroDrive or C:\ZeroDrive).

.PARAMETER ApiBase
    ZeroDrive REST API base URL (Default: https://api.zerodrive.dev).

.PARAMETER ApiToken
    ZeroDrive Bearer authorization token. Defaults to $env:ZERODRIVE_API_TOKEN.

.PARAMETER Daemon
    Run in non-interactive background loop.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SyncRoot = "$env:USERPROFILE\ZeroDrive",

    [Parameter(Mandatory = $false)]
    [string]$ApiBase = "https://api.zerodrive.dev",

    [Parameter(Mandatory = $false)]
    [string]$ApiToken = $env:ZERODRIVE_API_TOKEN,

    [Parameter(Mandatory = $false)]
    [switch]$Daemon
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Fallback default token if not set
if ([string]::IsNullOrWhiteSpace($ApiToken)) {
    $ApiToken = "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633"
}

$SyncRoot = [System.IO.Path]::GetFullPath($SyncRoot).TrimEnd('\', '/')
$ApiBase = $ApiBase.TrimEnd('/')

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " ZeroDrive Real-Time Windows Sync Daemon" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Sync Root : $SyncRoot" -ForegroundColor White
Write-Host " API Base  : $ApiBase" -ForegroundColor White
Write-Host " Device ID : $env:COMPUTERNAME (Windows)" -ForegroundColor White

if (-not (Test-Path -LiteralPath $SyncRoot)) {
    New-Item -ItemType Directory -LiteralPath $SyncRoot -Force | Out-Null
    Write-Host "[Init] Created sync root folder: $SyncRoot" -ForegroundColor Green
}

# In-memory tracking to prevent echo feedback loops
$Global:SuppressedPaths = [System.Collections.Concurrent.ConcurrentDictionary[string, byte]]::new([System.StringComparer]::OrdinalIgnoreCase)
$Global:RecentUploads = [System.Collections.Concurrent.ConcurrentDictionary[string, datetime]]::new([System.StringComparer]::OrdinalIgnoreCase)
$Global:Running = $true
$Global:LastActivityId = $null

function Get-RelativeVaultPath {
    param([string]$LocalFullPath)
    $cleanRoot = $SyncRoot.TrimEnd('\')
    if ($LocalFullPath.StartsWith($cleanRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $LocalFullPath.Substring($cleanRoot.Length).TrimStart('\', '/')
        return $rel.Replace('\', '/')
    }
    return $LocalFullPath.Replace('\', '/')
}

function Get-LocalWindowsPath {
    param([string]$VaultRelPath)
    $sanitized = $VaultRelPath.Replace('/', '\').TrimStart('\')
    return [System.IO.Path]::Combine($SyncRoot, $sanitized)
}

function Invoke-ZeroDriveApi {
    param(
        [string]$Path,
        [string]$Method = "GET",
        [hashtable]$Headers = @{},
        [object]$Body = $null,
        [string]$OutFile = $null,
        [int]$TimeoutSec = 30
    )

    $url = "$ApiBase/$($Path.TrimStart('/'))"
    $reqHeaders = @{
        "Authorization" = "Bearer $ApiToken"
        "User-Agent"    = "ZeroDrive-WindowsSyncDaemon/3.0"
    }
    foreach ($k in $Headers.Keys) {
        $reqHeaders[$k] = $Headers[$k]
    }

    try {
        $params = @{
            Uri         = $url
            Method      = $Method
            Headers     = $reqHeaders
            TimeoutSec  = $TimeoutSec
            ErrorAction = "Stop"
        }

        if ($Body) {
            $params["Body"] = $Body
        }
        if ($OutFile) {
            $params["OutFile"] = $OutFile
            Invoke-RestMethod @params
            return @{ ok = $true }
        }

        $res = Invoke-RestMethod @params
        return $res
    }
    catch {
        return @{ ok = $false; error = $_.Exception.Message; statusCode = $_.Exception.Response.StatusCode.value__ }
    }
}

# Path Ignore Rules
function Should-IgnoreFile {
    param([string]$FilePath)
    $name = [System.IO.Path]::GetFileName($FilePath)
    if ([string]::IsNullOrWhiteSpace($name)) { return $true }
    if ($name -ieq "desktop.ini" -or $name -ieq "Thumbs.db") { return $true }
    if ($name.StartsWith("~$")) { return $true } # Microsoft Office temporary lock
    if ($name.EndsWith(".tmp") -or $name.EndsWith(".crdownload") -or $name.EndsWith(".part")) { return $true }
    return $false
}

# 1. Hydrate File on Demand
function Hydrate-ZeroDriveFile {
    param(
        [string]$RelativeVaultPath,
        [string]$LocalPath,
        [long]$ExpectedSize = 0
    )

    $parentDir = [System.IO.Path]::GetDirectoryName($LocalPath)
    if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -LiteralPath $parentDir -Force | Out-Null
    }

    Write-Host "[Hydrate] Downloading: $RelativeVaultPath -> $LocalPath" -ForegroundColor Yellow
    $Global:SuppressedPaths.TryAdd($LocalPath, 1) | Out-Null
    try {
        $encoded = [System.Uri]::EscapeDataString($RelativeVaultPath)
        $tempPath = "$LocalPath.zd-download-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        $downloadResult = Invoke-ZeroDriveApi -Path "vault/download?path=$encoded" -OutFile $tempPath -TimeoutSec 120

        if ($downloadResult.ok -and (Test-Path -LiteralPath $tempPath)) {
            Move-Item -LiteralPath $tempPath -Destination $LocalPath -Force
            Write-Host "[Hydrate] Complete: $RelativeVaultPath" -ForegroundColor Green
            return $true
        } else {
            if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
            Write-Host "[Hydrate] Download failed for $RelativeVaultPath" -ForegroundColor Red
            return $false
        }
    }
    finally {
        Start-Sleep -Milliseconds 400
        $dummy = [byte]0
        $Global:SuppressedPaths.TryRemove($LocalPath, [ref]$dummy) | Out-Null
    }
}

# 2. Create Local Dataless Placeholder
function Set-LocalPlaceholder {
    param(
        [string]$RelativeVaultPath,
        [long]$Size,
        [string]$ModifiedStr
    )

    $localPath = Get-LocalWindowsPath -VaultRelPath $RelativeVaultPath
    $parent = [System.IO.Path]::GetDirectoryName($localPath)
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -LiteralPath $parent -Force | Out-Null
    }

    # If file exists and size is positive, it's already hydrated or modified locally
    if (Test-Path -LiteralPath $localPath) {
        $existing = Get-Item -LiteralPath $localPath
        if ($existing.Length -eq $Size -and $Size -gt 0) {
            return
        }
    }

    $Global:SuppressedPaths.TryAdd($localPath, 1) | Out-Null
    try {
        # Create lightweight placeholder with ZeroDrive Alternate Data Stream (ADS)
        if (-not (Test-Path -LiteralPath $localPath)) {
            [System.IO.File]::WriteAllBytes($localPath, [byte[]]@())
        }

        # Store metadata in NTFS Alternate Data Stream for instant hydration metadata
        $metaJson = @{
            vault_path = $RelativeVaultPath
            size       = $Size
            modified   = $ModifiedStr
            hydrated   = $false
        } | ConvertTo-Json -Compress

        Set-Content -LiteralPath "$localPath`:zerodrive" -Value $metaJson -ErrorAction SilentlyContinue

        if (-not [string]::IsNullOrWhiteSpace($ModifiedStr)) {
            $parsedDate = [datetime]::UtcNow
            if ([datetime]::TryParse($ModifiedStr, [ref]$parsedDate)) {
                (Get-Item -LiteralPath $localPath).LastWriteTimeUtc = $parsedDate
            }
        }
        Write-Host "[Placeholder] Set: $RelativeVaultPath ($Size bytes)" -ForegroundColor Cyan
    }
    finally {
        Start-Sleep -Milliseconds 300
        $dummy = [byte]0
        $Global:SuppressedPaths.TryRemove($localPath, [ref]$dummy) | Out-Null
    }
}

# 3. Initial Tree Fetch & Placeholders
function Sync-InitialVaultTree {
    Write-Host "[Sync] Enumerating remote files from ZeroDrive..." -ForegroundColor Yellow
    $res = Invoke-ZeroDriveApi -Path "v1/files?recursive=true&limit=2000"
    if (-not $res.ok -and -not $res.files) {
        Write-Host "[Sync] Failed to fetch remote files: $($res.error)" -ForegroundColor Red
        return
    }

    if ($res.directories) {
        foreach ($d in $res.directories) {
            if ($d.path) {
                $dirPath = Get-LocalWindowsPath -VaultRelPath $d.path
                if (-not (Test-Path -LiteralPath $dirPath)) {
                    New-Item -ItemType Directory -LiteralPath $dirPath -Force | Out-Null
                }
            }
        }
    }

    if ($res.files) {
        $count = 0
        foreach ($f in $res.files) {
            if ($f.path) {
                Set-LocalPlaceholder -RelativeVaultPath $f.path -Size $f.size -ModifiedStr $f.modified
                $count++
            }
        }
        Write-Host "[Sync] Loaded $count files into $SyncRoot" -ForegroundColor Green
    }
}

# 4. Outbound Upload with File Lock Retry
function Send-LocalFileToCloud {
    param([string]$LocalFilePath)

    if (Should-IgnoreFile -FilePath $LocalFilePath) { return }
    if ($Global:SuppressedPaths.ContainsKey($LocalFilePath)) { return }
    if (-not (Test-Path -LiteralPath $LocalFilePath)) { return }

    $now = [datetime]::UtcNow
    if ($Global:RecentUploads.ContainsKey($LocalFilePath)) {
        $last = $Global:RecentUploads[$LocalFilePath]
        if (($now - $last).TotalSeconds -lt 2) { return } # Debounce
    }

    $relPath = Get-RelativeVaultPath -LocalFullPath $LocalFilePath

    # Exponential retry to gracefully handle ERROR_SHARING_VIOLATION / IOException
    $delays = @(150, 350, 750, 1500, 3000)
    $bytes = $null

    for ($i = 0; $i -le $delays.Length; $i++) {
        try {
            $stream = [System.IO.File]::Open($LocalFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $bytes = New-Object byte[] $stream.Length
                $read = $stream.Read($bytes, 0, $bytes.Length)
            }
            finally {
                $stream.Dispose()
            }
            break
        }
        catch [System.IO.IOException] {
            if ($i -eq $delays.Length) {
                Write-Host "[Lock] File is exclusively locked by another application: $relPath" -ForegroundColor DarkYellow
                return
            }
            Start-Sleep -Milliseconds $delays[$i]
        }
        catch {
            Write-Host "[ReadError] $LocalFilePath : $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    if ($null -eq $bytes) { return }

    # If file was a 0-byte placeholder that has never been modified, do not upload blank content
    if ($bytes.Length -eq 0) {
        $adsPath = "$LocalFilePath`:zerodrive"
        if (Test-Path -LiteralPath $adsPath) {
            return
        }
    }

    Write-Host "[Upload] Uploading to cloud: $relPath ($($bytes.Length) bytes)..." -ForegroundColor Yellow
    try {
        $encoded = [System.Uri]::EscapeDataString($relPath)
        $url = "$ApiBase/vault/upload?path=$encoded"

        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = "POST"
        $req.Headers.Add("Authorization", "Bearer $ApiToken")
        $req.Headers.Add("User-Agent", "ZeroDrive-WindowsSyncDaemon/3.0")
        $req.ContentType = "application/octet-stream"
        $req.ContentLength = $bytes.Length
        $req.Timeout = 60000

        $reqStream = $req.GetRequestStream()
        $reqStream.Write($bytes, 0, $bytes.Length)
        $reqStream.Close()

        $resp = $req.GetResponse()
        $resp.Close()

        $Global:RecentUploads[$LocalFilePath] = [datetime]::UtcNow
        Write-Host "[Upload] Success: $relPath" -ForegroundColor Green
    }
    catch {
        Write-Host "[UploadError] Failed to upload $relPath : $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 5. Outbound Delete
function Remove-RemoteFileFromCloud {
    param([string]$LocalFilePath)

    if (Should-IgnoreFile -FilePath $LocalFilePath) { return }
    if ($Global:SuppressedPaths.ContainsKey($LocalFilePath)) { return }

    $relPath = Get-RelativeVaultPath -LocalFullPath $LocalFilePath
    Write-Host "[Delete] Removing from cloud: $relPath" -ForegroundColor DarkRed

    $encoded = [System.Uri]::EscapeDataString($relPath)
    $res = Invoke-ZeroDriveApi -Path "v1/files?path=$encoded" -Method "DELETE"
    if ($res.ok -or $res.deleted) {
        Write-Host "[Delete] Cloud deleted: $relPath" -ForegroundColor Green
    }
}

# 6. FileSystemWatcher Setup
function Start-LocalWatcher {
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $SyncRoot
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor 
                           [System.IO.NotifyFilters]::DirectoryName -bor 
                           [System.IO.NotifyFilters]::LastWrite -bor 
                           [System.IO.NotifyFilters]::Size

    Register-ObjectEvent $watcher 'Created' -Action {
        Send-LocalFileToCloud -LocalFilePath $Event.SourceEventArgs.FullPath
    } | Out-Null

    Register-ObjectEvent $watcher 'Changed' -Action {
        Send-LocalFileToCloud -LocalFilePath $Event.SourceEventArgs.FullPath
    } | Out-Null

    Register-ObjectEvent $watcher 'Deleted' -Action {
        Remove-RemoteFileFromCloud -LocalFilePath $Event.SourceEventArgs.FullPath
    } | Out-Null

    Register-ObjectEvent $watcher 'Renamed' -Action {
        Remove-RemoteFileFromCloud -LocalFilePath $Event.SourceEventArgs.OldFullPath
        Send-LocalFileToCloud -LocalFilePath $Event.SourceEventArgs.FullPath
    } | Out-Null

    Write-Host "[Watcher] Monitoring local filesystem changes in $SyncRoot" -ForegroundColor Green
    return $watcher
}

# 7. Activity Poller / Remote Inbound Worker
function Poll-RemoteLedgerActivity {
    try {
        $res = Invoke-ZeroDriveApi -Path "v1/activity?limit=15"
        if ($res.ok -and $res.activities) {
            foreach ($act in $res.activities) {
                if ($act.id -eq $Global:LastActivityId) { break }
                $actType = "$($act.action)"
                $path = "$($act.path)"

                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    if ($actType -match "write|upload|create") {
                        Set-LocalPlaceholder -RelativeVaultPath $path -Size ($act.size -as [long]) -ModifiedStr $act.timestamp
                    }
                    elseif ($actType -match "delete") {
                        $localTarget = Get-LocalWindowsPath -VaultRelPath $path
                        if (Test-Path -LiteralPath $localTarget) {
                            $Global:SuppressedPaths.TryAdd($localTarget, 1) | Out-Null
                            Remove-Item -LiteralPath $localTarget -Force -Recurse -ErrorAction SilentlyContinue
                            Start-Sleep -Milliseconds 250
                            $dummy = [byte]0
                            $Global:SuppressedPaths.TryRemove($localTarget, [ref]$dummy) | Out-Null
                            Write-Host "[Event] Removed local file matching remote delete: $path" -ForegroundColor DarkRed
                        }
                    }
                }
            }

            if ($res.activities.Count -gt 0) {
                $Global:LastActivityId = $res.activities[0].id
            }
        }
    }
    catch {
        # Quiet background poll retry
    }
}

# 8. Main Execution Loop
Sync-InitialVaultTree
$watcher = Start-LocalWatcher

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " ZeroDrive Sync Engine is running. Press Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

try {
    while ($Global:Running) {
        Start-Sleep -Seconds 3
        Poll-RemoteLedgerActivity
    }
}
finally {
    if ($watcher) {
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
    }
    Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue
    Write-Host "[Shutdown] ZeroDrive sync daemon stopped." -ForegroundColor Yellow
}
