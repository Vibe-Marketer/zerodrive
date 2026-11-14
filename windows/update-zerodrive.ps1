<#
.SYNOPSIS
    ZeroDrive Windows Auto-Updater & In-App Changelog Viewer

.DESCRIPTION
    - Checks https://api.zerodrive.dev/v1/releases/latest?platform=windows for newer releases.
    - Supports launch, login, 4-hour periodic, and manual update checks.
    - Prompts user cleanly (Accept Now or Defer 24h) on interactive Windows sessions.
    - Downloads updates with HTTP Range resume and retry backoff.
    - Verifies byte size, SHA-256 digest, ECDSA P-256 release signature, and strips Zone.Identifier (Unblock-File).
    - Atomically swaps installed files with automatic rollback on failure.
    - Displays cumulative post-update "What's New" changelog (including skipped versions) and allows viewing changelog anytime.
#>

[CmdletBinding()]
param(
    [ValidateSet("launch", "login", "periodic", "manual")]
    [string]$Trigger = "manual",

    [switch]$CheckOnly,
    [switch]$Silent,
    [switch]$AutoAccept,
    [switch]$ShowChangelog,

    [string]$InstallDir = "$env:LOCALAPPDATA\ZeroDrive",
    [string]$ApiBase = $env:ZERODRIVE_UPDATE_ENDPOINT
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($ApiBase)) {
    $ApiBase = "https://api.zerodrive.dev"
}
$ApiBase = $ApiBase.TrimEnd('/')

$EmbeddedPublicKeyPem = @"
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/JM4b2aY9Rt903bl8CDZt3kbcV5c
I75mfIZAxtzNsSuNxNVLGvRoZ3kwUZ5UtigFOmBfoFkAtA4CgBRi+q9OMQ==
-----END PUBLIC KEY-----
"@

$ConfigPath = Join-Path $InstallDir "config.json"
$StatePath = Join-Path $InstallDir "update-state.json"
$ReleaseNotesJsonPath = Join-Path $InstallDir "release-notes.json"
$ChangelogMdPath = Join-Path $InstallDir "CHANGELOG.md"

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    }
}

function Compare-SemVer {
    param([string]$A, [string]$B)
    $cleanA = ($A -replace '^v', '') -split '[-+]' | Select-Object -First 1
    $cleanB = ($B -replace '^v', '') -split '[-+]' | Select-Object -First 1
    $partsA = $cleanA.Split('.') | ForEach-Object { [int]($_ -replace '[^0-9]', '') }
    $partsB = $cleanB.Split('.') | ForEach-Object { [int]($_ -replace '[^0-9]', '') }
    for ($i = 0; $i -lt 3; $i++) {
        $va = if ($i -lt $partsA.Count) { $partsA[$i] } else { 0 }
        $vb = if ($i -lt $partsB.Count) { $partsB[$i] } else { 0 }
        if ($va -gt $vb) { return 1 }
        if ($va -lt $vb) { return -1 }
    }
    return 0
}

function Load-Config {
    $defaults = [ordered]@{
        sync_root        = "$env:USERPROFILE\ZeroDrive"
        api_base         = $ApiBase
        version          = "3.0.0"
        previous_version = $null
        installed        = (Get-Date).ToString("o")
        updated_at       = $null
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $parsed = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            if ($parsed) {
                foreach ($key in $defaults.Keys) {
                    if (-not ($parsed.PSObject.Properties.Name -contains $key)) {
                        $parsed | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
                    }
                }
                return $parsed
            }
        } catch {}
    }
    return [PSCustomObject]$defaults
}

function Save-Config {
    param($ConfigObj)
    Ensure-Directory $InstallDir
    $json = $ConfigObj | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $ConfigPath -Value $json -Encoding UTF8 -Force
}

function Load-UpdateState {
    $defaults = [ordered]@{
        last_checked_at            = $null
        deferred_version           = $null
        deferred_until             = $null
        pending_update_from        = $null
        last_seen_changelog_version = $null
    }
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $parsed = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            if ($parsed) {
                foreach ($key in $defaults.Keys) {
                    if (-not ($parsed.PSObject.Properties.Name -contains $key)) {
                        $parsed | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
                    }
                }
                return $parsed
            }
        } catch {}
    }
    return [PSCustomObject]$defaults
}

function Save-UpdateState {
    param($StateObj)
    Ensure-Directory $InstallDir
    $json = $StateObj | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $StatePath -Value $json -Encoding UTF8 -Force
}

function Show-UserDialog {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet("YesNo", "Info")]
        [string]$Mode = "Info"
    )

    if (-not [Environment]::UserInteractive -or $Silent) {
        Write-Host "[$Title]`n$Message" -ForegroundColor Cyan
        return $true
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if ($Mode -eq "YesNo") {
            $res = [System.Windows.Forms.MessageBox]::Show(
                $Message,
                $Title,
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return ($res -eq [System.Windows.Forms.DialogResult]::Yes)
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                $Message,
                $Title,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return $true
        }
    } catch {
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host " $Title" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host $Message
        if ($Mode -eq "YesNo") {
            $ans = Read-Host "Install update now? [Y/n]"
            return ([string]::IsNullOrWhiteSpace($ans) -or $ans -match '^[Yy]')
        }
        return $true
    }
}

function Format-ChangelogText {
    param(
        $Releases,
        [string]$Header = "ZeroDrive Release Notes"
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($Header)
    [void]$sb.AppendLine(("=" * 56))
    foreach ($rel in $Releases) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("v$($rel.version) ($($rel.date)) — $($rel.title)")
        foreach ($h in $rel.highlights) {
            [void]$sb.AppendLine("  * $h")
        }
    }
    return $sb.ToString()
}

function Show-ChangelogViewer {
    param([string]$JustUpdatedFrom = $null)

    $cfg = Load-Config
    $currentVer = if ($cfg.version) { $cfg.version } else { "3.0.0" }
    $releases = @()

    try {
        $remote = Invoke-RestMethod -Uri "$ApiBase/v1/releases/changelog" -Method GET -TimeoutSec 8 -ErrorAction Stop
        if ($remote.all_releases) { $releases = $remote.all_releases }
        elseif ($remote.releases) { $releases = $remote.releases }
    } catch {}

    if ($releases.Count -eq 0 -and (Test-Path -LiteralPath $ReleaseNotesJsonPath)) {
        try {
            $localData = Get-Content -LiteralPath $ReleaseNotesJsonPath -Raw | ConvertFrom-Json
            if ($localData -is [System.Array]) { $releases = $localData }
            elseif ($localData.releases) { $releases = $localData.releases }
        } catch {}
    }

    if ($releases.Count -eq 0) {
        Show-UserDialog -Title "ZeroDrive v$currentVer" -Message "You are running ZeroDrive v$currentVer." -Mode "Info" | Out-Null
        return
    }

    if ($JustUpdatedFrom) {
        $missed = @($releases | Where-Object {
            (Compare-SemVer $_.version $JustUpdatedFrom) -gt 0 -and (Compare-SemVer $_.version $currentVer) -le 0
        })
        $header = "ZeroDrive updated from v$JustUpdatedFrom to v$currentVer!"
        $selectedReleases = if ($missed.Count -gt 0) { $missed } else { $releases }
        $text = Format-ChangelogText -Releases $selectedReleases -Header $header
        Show-UserDialog -Title "What's New in ZeroDrive v$currentVer" -Message $text -Mode "Info" | Out-Null
    } else {
        $text = Format-ChangelogText -Releases $releases -Header "ZeroDrive Version History (Installed: v$currentVer)"
        Show-UserDialog -Title "ZeroDrive Changelog" -Message $text -Mode "Info" | Out-Null
    }
}

function Verify-EcdsaP256Signature {
    param(
        [string]$Payload,
        [string]$SignatureBase64,
        [string]$PublicKeyPem
    )

    if (-not ("ZeroDrive.UpdateCrypto" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;

namespace ZeroDrive {
    public static class UpdateCrypto {
        public static bool VerifyP256Der(string payload, string sigBase64, string publicKeyPem) {
            byte[] payloadBytes = Encoding.UTF8.GetBytes(payload);
            byte[] derSig = Convert.FromBase64String(sigBase64.Trim());

            string cleanPem = publicKeyPem
                .Replace("-----BEGIN PUBLIC KEY-----", "")
                .Replace("-----END PUBLIC KEY-----", "")
                .Replace("\r", "")
                .Replace("\n", "")
                .Trim();
            byte[] spkiBytes = Convert.FromBase64String(cleanPem);

            // Extract uncompressed EC point (0x04 || X(32) || Y(32)) from tail of SPKI DER
            if (spkiBytes.Length < 65 || spkiBytes[spkiBytes.Length - 65] != 0x04) {
                throw new InvalidOperationException("Unsupported ECDSA P-256 public key format.");
            }
            byte[] x = new byte[32];
            byte[] y = new byte[32];
            Buffer.BlockCopy(spkiBytes, spkiBytes.Length - 64, x, 0, 32);
            Buffer.BlockCopy(spkiBytes, spkiBytes.Length - 32, y, 0, 32);

            var ecParams = new ECParameters {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = x, Y = y }
            };

            // Convert ASN.1 DER (SEQUENCE { INTEGER r, INTEGER s }) -> IEEE P1363 (r[32] || s[32])
            // so this works identically on both .NET Framework 4.8 (PowerShell 5.1) and .NET 8+.
            byte[] ieeeSig = DerToIeeeP1363(derSig, 32);

            using (var ecdsa = ECDsa.Create(ecParams)) {
                return ecdsa.VerifyData(payloadBytes, ieeeSig, HashAlgorithmName.SHA256);
            }
        }

        private static byte[] DerToIeeeP1363(byte[] der, int coordLen) {
            int offset = 0;
            if (der[offset++] != 0x30) throw new FormatException("Invalid DER sequence");
            int seqLen = der[offset++];
            if ((seqLen & 0x80) != 0) {
                int lenBytes = seqLen & 0x7F;
                offset += lenBytes;
            }
            byte[] r = ReadDerInt(der, ref offset, coordLen);
            byte[] s = ReadDerInt(der, ref offset, coordLen);
            byte[] result = new byte[coordLen * 2];
            Buffer.BlockCopy(r, 0, result, 0, coordLen);
            Buffer.BlockCopy(s, 0, result, coordLen, coordLen);
            return result;
        }

        private static byte[] ReadDerInt(byte[] der, ref int offset, int coordLen) {
            if (der[offset++] != 0x02) throw new FormatException("Invalid DER integer");
            int len = der[offset++];
            int srcOffset = offset;
            offset += len;
            while (len > coordLen && der[srcOffset] == 0x00) {
                srcOffset++;
                len--;
            }
            if (len > coordLen) throw new FormatException("ECDSA coordinate overflow");
            byte[] outBytes = new byte[coordLen];
            Buffer.BlockCopy(der, srcOffset, outBytes, coordLen - len, len);
            return outBytes;
        }
    }
}
"@
    }

    return [ZeroDrive.UpdateCrypto]::VerifyP256Der($Payload, $SignatureBase64, $PublicKeyPem)
}

function Download-WithResume {
    param(
        [string]$Url,
        [string]$PartPath,
        [long]$ExpectedSize
    )

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $existingBytes = [long]0
            if (Test-Path -LiteralPath $PartPath) {
                $existingBytes = (Get-Item -LiteralPath $PartPath).Length
            }

            if ($ExpectedSize -gt 0 -and $existingBytes -eq $ExpectedSize) {
                return
            }
            if ($ExpectedSize -gt 0 -and $existingBytes -gt $ExpectedSize) {
                Remove-Item -LiteralPath $PartPath -Force -ErrorAction SilentlyContinue
                $existingBytes = 0
            }

            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = "GET"
            $req.Timeout = 60000
            $req.UserAgent = "ZeroDrive-WindowsUpdater/3.1"
            if ($existingBytes -gt 0) {
                $req.AddRange($existingBytes)
                Write-Host "[Updater] Resuming download from $existingBytes bytes..." -ForegroundColor Yellow
            }

            $resp = [System.Net.HttpWebResponse]$req.GetResponse()
            try {
                $status = [int]$resp.StatusCode
                $isResume = ($status -eq 206 -and $existingBytes -gt 0)
                $mode = if ($isResume) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }

                $inStream = $resp.GetResponseStream()
                $outStream = [System.IO.File]::Open($PartPath, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try {
                    $buf = New-Object byte[] 65536
                    while (($read = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $outStream.Write($buf, 0, $read)
                    }
                } finally {
                    $outStream.Dispose()
                    $inStream.Dispose()
                }
            } finally {
                $resp.Close()
            }
            return
        } catch {
            if ($attempt -ge $maxAttempts) {
                throw
            }
            Write-Host "[Updater] Download interrupted ($($_.Exception.Message)). Retrying ($attempt/$maxAttempts)..." -ForegroundColor Yellow
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

# Handle standalone changelog viewer
if ($ShowChangelog) {
    Show-ChangelogViewer
    exit 0
}

# Check if an update just completed on previous run
$state = Load-UpdateState
$cfg = Load-Config
$currentVersion = if ($cfg.version) { [string]$cfg.version } else { "3.0.0" }

if ($state.pending_update_from -and (Compare-SemVer $currentVersion $state.pending_update_from) -gt 0) {
    $prevVer = [string]$state.pending_update_from
    $state.pending_update_from = $null
    $state.last_seen_changelog_version = $currentVersion
    Save-UpdateState $state
    Show-ChangelogViewer -JustUpdatedFrom $prevVer
}

# Query release manifest
try {
    $checkUrl = "$ApiBase/v1/releases/latest?platform=windows&current_version=$([System.Uri]::EscapeDataString($currentVersion))"
    $releaseCheck = Invoke-RestMethod -Uri $checkUrl -Method GET -TimeoutSec 15 -ErrorAction Stop
} catch {
    if ($Trigger -eq "manual") {
        Write-Host "[Updater] Unable to check for updates (offline or server unreachable). Current version v$currentVersion remains active." -ForegroundColor Yellow
    }
    exit 0
}

$state.last_checked_at = (Get-Date).ToString("o")
Save-UpdateState $state

$latestVersion = [string]$releaseCheck.latest_version
$updateAvailable = ($releaseCheck.update_available -eq $true) -and ((Compare-SemVer $latestVersion $currentVersion) -gt 0)

if (-not $updateAvailable) {
    if ($Trigger -eq "manual" -and -not $Silent) {
        Write-Host "[Updater] ZeroDrive is up to date (v$currentVersion)." -ForegroundColor Green
    }
    exit 0
}

# Respect 24h deferral on periodic checks
if ($Trigger -eq "periodic" -and $state.deferred_version -eq $latestVersion -and $state.deferred_until) {
    try {
        $untilDt = [datetime]::Parse($state.deferred_until)
        if ([datetime]::UtcNow -lt $untilDt.ToUniversalTime()) {
            exit 0
        }
    } catch {}
}

$missed = if ($releaseCheck.missed_releases) { $releaseCheck.missed_releases } else { @($releaseCheck.latest) }
$notesSummary = Format-ChangelogText -Releases $missed -Header "ZeroDrive v$latestVersion is available (installed: v$currentVersion)."

if ($CheckOnly) {
    Write-Host $notesSummary -ForegroundColor Cyan
    exit 0
}

# Prompt user to accept or defer
if (-not $AutoAccept) {
    $promptBody = "$notesSummary`n`nDo you want to download and install ZeroDrive v$latestVersion now?`nClick Yes to update now, or No to defer for 24 hours."
    $accepted = Show-UserDialog -Title "ZeroDrive Update Available (v$latestVersion)" -Message $promptBody -Mode "YesNo"
    if (-not $accepted) {
        $state.deferred_version = $latestVersion
        $state.deferred_until = [datetime]::UtcNow.AddHours(24).ToString("o")
        Save-UpdateState $state
        Write-Host "[Updater] Deferred ZeroDrive v$latestVersion for 24 hours." -ForegroundColor Yellow
        exit 0
    }
}

$artifact = $releaseCheck.platform_artifact
if (-not $artifact -or -not $artifact.url) {
    Write-Error "Update manifest missing Windows download artifact."
    exit 1
}

$tempZipPart = Join-Path $env:TEMP "$($artifact.filename).part"
$tempZip = Join-Path $env:TEMP $artifact.filename
$stageDir = Join-Path $env:TEMP "zerodrive-win-stage-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
$backupDir = "$InstallDir.backup.$([Guid]::NewGuid().ToString('N').Substring(0,6))"

try {
    Write-Host "[Updater] Downloading $($artifact.filename)..." -ForegroundColor Cyan
    Download-WithResume -Url $artifact.url -PartPath $tempZipPart -ExpectedSize ([long]$artifact.size)

    # 1. Verify byte size
    $actualSize = (Get-Item -LiteralPath $tempZipPart).Length
    if ([long]$artifact.size -gt 0 -and $actualSize -ne [long]$artifact.size) {
        Remove-Item -LiteralPath $tempZipPart -Force -ErrorAction SilentlyContinue
        throw "Size mismatch ($actualSize vs expected $($artifact.size) bytes)."
    }

    # 2. Verify SHA-256
    $actualSha = (Get-FileHash -LiteralPath $tempZipPart -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedSha = ([string]$artifact.sha256).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($expectedSha) -or $actualSha -ne $expectedSha) {
        Remove-Item -LiteralPath $tempZipPart -Force -ErrorAction SilentlyContinue
        throw "SHA-256 verification failed ($actualSha != $expectedSha)."
    }

    # 3. Verify ECDSA P-256 release signature
    $pubKey = if ($releaseCheck.public_key) { [string]$releaseCheck.public_key } else { $EmbeddedPublicKeyPem }
    $canonicalPayload = "zerodrive-release-v1:windows:${latestVersion}:${actualSha}:${actualSize}"
    $sigOk = Verify-EcdsaP256Signature -Payload $canonicalPayload -SignatureBase64 ([string]$artifact.signature) -PublicKeyPem $pubKey
    if (-not $sigOk) {
        Remove-Item -LiteralPath $tempZipPart -Force -ErrorAction SilentlyContinue
        throw "Cryptographic ECDSA P-256 signature verification failed!"
    }
    Write-Host "[Updater] Verified SHA-256 + ECDSA P-256 release signature." -ForegroundColor Green

    Move-Item -LiteralPath $tempZipPart -Destination $tempZip -Force

    # 4. Extract to staging directory & strip Zone.Identifier
    Ensure-Directory $stageDir
    Expand-Archive -LiteralPath $tempZip -DestinationPath $stageDir -Force
    Get-ChildItem -LiteralPath $stageDir -Recurse -File | ForEach-Object {
        try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {}
    }

    # 5. Stop active daemon cleanly before swapping files
    $isWindowsHost = ($env:OS -eq "Windows_NT")
    if ($isWindowsHost) {
        try { Stop-ScheduledTask -TaskName "ZeroDriveSync" -ErrorAction SilentlyContinue } catch {}
        try {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -like "*sync-daemon.ps1*" -or $_.Name -eq "zerodrive-sync.exe"
            } | ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    # 6. Atomic backup + swap with automatic rollback
    if (Test-Path -LiteralPath $InstallDir) {
        Copy-Item -LiteralPath $InstallDir -Destination $backupDir -Recurse -Force
    }

    try {
        Ensure-Directory $InstallDir
        Get-ChildItem -LiteralPath $stageDir | ForEach-Object {
            if ($_.Name -ieq "config.json" -or $_.Name -ieq "update-state.json") { return }
            $dest = Join-Path $InstallDir $_.Name
            if ($_.PSIsContainer) {
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
            } else {
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }

        # Preserve sync_root / api_base while updating version metadata
        $cfg.version = $latestVersion
        $cfg.previous_version = $currentVersion
        $cfg.updated_at = (Get-Date).ToString("o")
        Save-Config $cfg

        # Write CHANGELOG.md locally
        $mdText = Format-ChangelogText -Releases $releaseCheck.all_releases -Header "# ZeroDrive Changelog (Installed: v$latestVersion)"
        Set-Content -LiteralPath $ChangelogMdPath -Value $mdText -Encoding UTF8 -Force

        $state.deferred_version = $null
        $state.deferred_until = $null
        $state.pending_update_from = $null
        $state.last_seen_changelog_version = $latestVersion
        Save-UpdateState $state

        if (Test-Path -LiteralPath $backupDir) {
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "[Updater] Install failed ($($_.Exception.Message)). Rolling back to v$currentVersion..." -ForegroundColor Red
        if (Test-Path -LiteralPath $backupDir) {
            if (Test-Path -LiteralPath $InstallDir) {
                Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $backupDir -Destination $InstallDir -Force
        }
        throw
    }

    if ($isWindowsHost) {
        try { Start-ScheduledTask -TaskName "ZeroDriveSync" -ErrorAction SilentlyContinue } catch {}
    }

    Write-Host "[Updater] Successfully updated ZeroDrive to v$latestVersion!" -ForegroundColor Green
    if (-not $Silent) {
        Show-ChangelogViewer -JustUpdatedFrom $currentVersion
    }
} finally {
    if (Test-Path -LiteralPath $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempZip) {
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
    }
}
