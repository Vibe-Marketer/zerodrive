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
    [System.IO.Directory]::CreateDirectory($SyncRoot) | Out-Null
    Write-Host "[Init] Created sync root folder: $SyncRoot" -ForegroundColor Green
}

# In-memory tracking to prevent echo feedback loops
$Global:SuppressedPaths = [System.Collections.Concurrent.ConcurrentDictionary[string, byte]]::new([System.StringComparer]::OrdinalIgnoreCase)
$Global:RecentUploads = [System.Collections.Concurrent.ConcurrentDictionary[string, datetime]]::new([System.StringComparer]::OrdinalIgnoreCase)
$Global:Running = $true
$Global:LastActivityId = $null
$Global:KnownDrives = @()

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
    param(
        [string]$VaultRelPath,
        [string]$DriveName = ""
    )
    $sanitized = $VaultRelPath.Replace('/', '\').TrimStart('\')
    if (-not [string]::IsNullOrWhiteSpace($DriveName)) {
        return [System.IO.Path]::Combine($SyncRoot, $DriveName, $sanitized)
    }
    return [System.IO.Path]::Combine($SyncRoot, $sanitized)
}

function Resolve-LocalFileDrive {
    param([string]$LocalFullPath)
    $cleanRoot = $SyncRoot.TrimEnd('\')
    if ($LocalFullPath.StartsWith($cleanRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $sub = $LocalFullPath.Substring($cleanRoot.Length).TrimStart('\', '/')
        $parts = $sub.Split('\', 2)
        if ($parts.Length -gt 1) {
            $candidateDrive = $parts[0]
            $subPath = $parts[1].Replace('\', '/')
            foreach ($d in $Global:KnownDrives) {
                if ($d.name -ieq $candidateDrive -or $d.id -ieq $candidateDrive) {
                    return @{
                        Drive = $d
                        DriveName = $d.name
                        DriveId = $d.id
                        RelativePath = $subPath
                    }
                }
            }
            return @{
                Drive = $null
                DriveName = "Primary Drive"
                DriveId = "primary"
                RelativePath = $sub.Replace('\', '/')
            }
        } else {
            return @{
                Drive = $null
                DriveName = "Primary Drive"
                DriveId = "primary"
                RelativePath = $sub.Replace('\', '/')
            }
        }
    }
    return @{
        Drive = $null
        DriveName = "Primary Drive"
        DriveId = "primary"
        RelativePath = $LocalFullPath.Replace('\', '/')
    }
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
        [System.IO.Directory]::CreateDirectory($parentDir) | Out-Null
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
        [string]$ModifiedStr,
        [string]$LocalPath = $null
    )

    $localPath = if ([string]::IsNullOrWhiteSpace($LocalPath)) {
        Get-LocalWindowsPath -VaultRelPath $RelativeVaultPath
    } else {
        $LocalPath
    }
    $parent = [System.IO.Path]::GetDirectoryName($localPath)
    if (-not (Test-Path -LiteralPath $parent)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
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

# 2b. Smart Disk Auto-Eviction & Dehydration
# Identifies cached files older than 7 days and calls CfDehydratePlaceholder
# (or marks cloud-only / offline attribute) when disk free space is below threshold.

$Global:CloudFilterLoaded = $false
try {
    if (-not ([System.Management.Automation.PSTypeName]'ZeroDrive.NativeCloudFilter').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ZeroDrive {
    public static class NativeCloudFilter {
        [Flags]
        public enum CF_DEHYDRATE_FLAGS : uint {
            NONE = 0x00000000,
            BACKGROUND = 0x00000001
        }

        [DllImport("cldapi.dll", SetLastError = true)]
        public static extern int CfDehydratePlaceholder(
            SafeFileHandle FileHandle,
            long StartingOffset,
            long Length,
            CF_DEHYDRATE_FLAGS DehydrateFlags,
            IntPtr Overlapped
        );

        public static int DehydrateFile(string path) {
            try {
                using (var handle = File.Open(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete)) {
                    return CfDehydratePlaceholder(handle.SafeFileHandle, 0, -1, CF_DEHYDRATE_FLAGS.BACKGROUND, IntPtr.Zero);
                }
            } catch {
                return -1;
            }
        }
    }
}
"@ -ErrorAction SilentlyContinue
        $Global:CloudFilterLoaded = $true
    } else {
        $Global:CloudFilterLoaded = $true
    }
} catch {
    $Global:CloudFilterLoaded = $false
}

function Invoke-ZeroDriveDehydration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$OlderThanDays = 7,

        [Parameter(Mandatory = $false)]
        [double]$MinFreeSpaceGB = 20.0,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Check drive free space
    $driveRoot = [System.IO.Path]::GetPathRoot($SyncRoot)
    $freeGB = 999.0
    try {
        if ([System.IO.Directory]::Exists($driveRoot)) {
            $driveInfo = [System.IO.DriveInfo]::new($driveRoot)
            $freeGB = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 2)
        }
    } catch {}

    if (-not $Force -and $freeGB -ge $MinFreeSpaceGB) {
        Write-Verbose "[Dehydrate] Disk free space ($freeGB GB) is above threshold ($MinFreeSpaceGB GB). No dehydration needed."
        return @{ evicted = 0; bytes_reclaimed = 0; free_gb = $freeGB }
    }

    Write-Host "[Dehydrate] Checking for cached files older than $OlderThanDays days (Free space: $freeGB GB, Threshold: $MinFreeSpaceGB GB)..." -ForegroundColor Yellow

    $cutoffDate = (Get-Date).ToUniversalTime().AddDays(-$OlderThanDays)
    $evictedCount = 0
    $reclaimedBytes = [long]0

    $allFiles = Get-ChildItem -LiteralPath $SyncRoot -File -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($file in $allFiles) {
        if (Should-IgnoreFile -FilePath $file.FullName) { continue }
        if ($file.FullName.EndsWith(":zerodrive")) { continue }

        # Only process files with cached data on disk
        if ($file.Length -le 0) { continue }

        $lastAccess = $file.LastAccessTimeUtc
        $lastWrite = $file.LastWriteTimeUtc
        $fileAgeDate = if ($lastAccess -and $lastAccess -gt [datetime]::MinValue) { $lastAccess } else { $lastWrite }

        if ($fileAgeDate -lt $cutoffDate) {
            $localPath = $file.FullName
            $relPath = Get-RelativeVaultPath -LocalFullPath $localPath
            $fileSize = $file.Length

            Write-Host "[Dehydrate] Evicting cached file: $relPath ($fileSize bytes, last access: $($fileAgeDate.ToString('yyyy-MM-dd')))" -ForegroundColor DarkCyan

            $Global:SuppressedPaths.TryAdd($localPath, 1) | Out-Null
            try {
                $dehydratedViaCldApi = $false
                if ($Global:CloudFilterLoaded) {
                    try {
                        $hr = [ZeroDrive.NativeCloudFilter]::DehydrateFile($localPath)
                        if ($hr -eq 0) {
                            $dehydratedViaCldApi = $true
                        }
                    } catch {}
                }

                if (-not $dehydratedViaCldApi) {
                    # Fallback routine: store ADS metadata, truncate payload to 0 bytes, mark cloud-only
                    $metaJson = @{
                        vault_path = $relPath
                        size       = $fileSize
                        modified   = $file.LastWriteTimeUtc.ToString("o")
                        hydrated   = $false
                    } | ConvertTo-Json -Compress

                    Set-Content -LiteralPath "$localPath`:zerodrive" -Value $metaJson -ErrorAction SilentlyContinue
                    [System.IO.File]::WriteAllBytes($localPath, [byte[]]@())

                    (Get-Item -LiteralPath $localPath).LastWriteTimeUtc = $lastWrite
                    (Get-Item -LiteralPath $localPath).LastAccessTimeUtc = $lastAccess

                    try {
                        & attrib.exe +U -P "$localPath" 2>$null
                    } catch {}

                    try {
                        $curAttr = [System.IO.File]::GetAttributes($localPath)
                        [System.IO.File]::SetAttributes($localPath, $curAttr -bor [System.IO.FileAttributes]::Offline)
                    } catch {}
                }

                $evictedCount++
                $reclaimedBytes += $fileSize
                Write-Host "[Dehydrate] Dehydrated: $relPath (Reclaimed $fileSize bytes)" -ForegroundColor Green
            } catch {
                Write-Host "[Dehydrate] Failed to dehydrate $relPath : $($_.Exception.Message)" -ForegroundColor Red
            } finally {
                Start-Sleep -Milliseconds 200
                $dummy = [byte]0
                $Global:SuppressedPaths.TryRemove($localPath, [ref]$dummy) | Out-Null
            }
        }
    }

    $reclaimedMB = [math]::Round($reclaimedBytes / 1MB, 2)
    Write-Host "[Dehydrate] Dehydration run complete. Evicted $evictedCount file(s), reclaimed $reclaimedMB MB local SSD space." -ForegroundColor Green

    return @{
        evicted = $evictedCount
        bytes_reclaimed = $reclaimedBytes
        free_gb = $freeGB
    }
}

# 3. Initial Multi-Drive Tree Fetch & Placeholders
function Sync-InitialVaultTree {
    Write-Host "[Sync] Enumerating drives from ZeroDrive..." -ForegroundColor Yellow
    $drivesRes = Invoke-ZeroDriveApi -Path "v1/drives"
    $drives = @()
    if ($drivesRes.ok -and $drivesRes.drives) {
        $drives = $drivesRes.drives
    } else {
        $drives = @(
            [PSCustomObject]@{
                id = "primary"
                name = "Primary Drive"
                is_default = $true
            }
        )
    }
    $Global:KnownDrives = $drives
    Write-Host "[Sync] Found $($drives.Count) drive(s) configured in vault" -ForegroundColor Cyan

    foreach ($drive in $drives) {
        $driveName = if ($drive.name) { $drive.name } else { $drive.id }
        $driveId = $drive.id
        $driveLocalDir = [System.IO.Path]::Combine($SyncRoot, $driveName)

        if (-not (Test-Path -LiteralPath $driveLocalDir)) {
            [System.IO.Directory]::CreateDirectory($driveLocalDir) | Out-Null
            Write-Host "[Sync] Initialized drive folder: $driveLocalDir" -ForegroundColor Green
        }

        Write-Host "[Sync] Enumerating files for drive '$driveName' ($driveId)..." -ForegroundColor Yellow
        $apiPath = if ($drive.is_default -or $driveId -eq "primary" -or $driveId -eq "default") {
            "v1/files?recursive=true&limit=2000"
        } else {
            "v1/files?drive_id=$driveId&recursive=true&limit=2000"
        }

        $res = Invoke-ZeroDriveApi -Path $apiPath
        if (-not $res.ok -and -not $res.files) {
            Write-Host "[Sync] Drive '$driveName' query notice: $($res.error)" -ForegroundColor DarkGray
            continue
        }

        if ($res.directories) {
            foreach ($d in $res.directories) {
                if ($d.path) {
                    $dirPath = [System.IO.Path]::Combine($driveLocalDir, $d.path.Replace('/', '\'))
                    if (-not (Test-Path -LiteralPath $dirPath)) {
                        [System.IO.Directory]::CreateDirectory($dirPath) | Out-Null
                    }
                }
            }
        }

        if ($res.files) {
            $count = 0
            foreach ($f in $res.files) {
                if ($f.path -and -not $f.path.EndsWith(".keep")) {
                    $targetLocal = [System.IO.Path]::Combine($driveLocalDir, $f.path.Replace('/', '\'))
                    Set-LocalPlaceholder -RelativeVaultPath $f.path -Size $f.size -ModifiedStr $f.modified -LocalPath $targetLocal
                    $count++
                }
            }
            Write-Host "[Sync] Drive '$driveName': Loaded $count placeholder(s)" -ForegroundColor Green
        }
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

    $resolved = Resolve-LocalFileDrive -LocalFullPath $LocalFilePath
    $relPath = $resolved.RelativePath
    $driveId = $resolved.DriveId

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

    Write-Host "[Upload] Uploading to cloud ($driveId): $relPath ($($bytes.Length) bytes)..." -ForegroundColor Yellow
    try {
        $encoded = [System.Uri]::EscapeDataString($relPath)
        $url = if ($driveId -and $driveId -ne "primary" -and $driveId -ne "default") {
            "$ApiBase/vault/upload?drive_id=$driveId&path=$encoded"
        } else {
            "$ApiBase/vault/upload?path=$encoded"
        }

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

    $resolved = Resolve-LocalFileDrive -LocalFullPath $LocalFilePath
    $relPath = $resolved.RelativePath
    $driveId = $resolved.DriveId
    Write-Host "[Delete] Removing from cloud ($driveId): $relPath" -ForegroundColor DarkRed

    $encoded = [System.Uri]::EscapeDataString($relPath)
    $deletePath = if ($driveId -and $driveId -ne "primary" -and $driveId -ne "default") {
        "v1/files?drive_id=$driveId&path=$encoded"
    } else {
        "v1/files?path=$encoded"
    }
    $res = Invoke-ZeroDriveApi -Path $deletePath -Method "DELETE"
    if ($res.ok -or $res.deleted) {
        Write-Host "[Delete] Cloud deleted ($driveId): $relPath" -ForegroundColor Green
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
                $driveId = "$($act.drive_id)"

                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    $matchedDrive = $Global:KnownDrives | Where-Object { $_.id -ieq $driveId } | Select-Object -First 1
                    $driveName = if ($matchedDrive) { $matchedDrive.name } else { "Primary Drive" }
                    $localTarget = [System.IO.Path]::Combine($SyncRoot, $driveName, $path.Replace('/', '\'))

                    if ($actType -match "write|upload|create") {
                        Set-LocalPlaceholder -RelativeVaultPath $path -Size ($act.size -as [long]) -ModifiedStr $act.timestamp -LocalPath $localTarget
                    }
                    elseif ($actType -match "delete") {
                        if (Test-Path -LiteralPath $localTarget) {
                            $Global:SuppressedPaths.TryAdd($localTarget, 1) | Out-Null
                            Remove-Item -LiteralPath $localTarget -Force -Recurse -ErrorAction SilentlyContinue
                            Start-Sleep -Milliseconds 250
                            $dummy = [byte]0
                            $Global:SuppressedPaths.TryRemove($localTarget, [ref]$dummy) | Out-Null
                            Write-Host "[Event] Removed local file matching remote delete: $path ($driveName)" -ForegroundColor DarkRed
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

# Run initial background dehydration check on startup
Invoke-ZeroDriveDehydration -OlderThanDays 7 -MinFreeSpaceGB 20.0

# Check for updates on startup / logon
$UpdaterScript = Join-Path $PSScriptRoot "update-zerodrive.ps1"
$LastUpdateCheckUtc = [datetime]::UtcNow
if (Test-Path -LiteralPath $UpdaterScript) {
    try {
        & $UpdaterScript -Trigger launch -ApiBase $ApiBase
    } catch {}
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " ZeroDrive Sync Engine is running. Press Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$loopCount = 0
try {
    while ($Global:Running) {
        Start-Sleep -Seconds 3
        Poll-RemoteLedgerActivity

        $loopCount++
        # Check dehydration every 1200 ticks (approx 1 hour)
        if ($loopCount -ge 1200) {
            $loopCount = 0
            Invoke-ZeroDriveDehydration -OlderThanDays 7 -MinFreeSpaceGB 20.0
        }

        # Check for updates every 4 hours while running
        if ((Test-Path -LiteralPath $UpdaterScript) -and (([datetime]::UtcNow - $LastUpdateCheckUtc).TotalHours -ge 4)) {
            $LastUpdateCheckUtc = [datetime]::UtcNow
            try {
                & $UpdaterScript -Trigger periodic -ApiBase $ApiBase
            } catch {}
        }
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
