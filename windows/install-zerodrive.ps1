<#
.SYNOPSIS
    ZeroDrive Windows Installer & Shell Integrator
    Installs ZeroDrive, configures Explorer navigation pane, and registers background sync service.

.DESCRIPTION
    1. Validates or prompts for ZeroDrive API Token.
    2. Sets up C:\Users\$env:USERNAME\ZeroDrive folder.
    3. Pins ZeroDrive to the Windows Explorer Left Navigation Pane via Registry CLSID.
    4. Registers Windows SyncRootManager integration.
    5. Creates a background Scheduled Task running at user logon with auto-restart.

.PARAMETER ApiToken
    ZeroDrive API token. If omitted, checks $env:ZERODRIVE_API_TOKEN or prompts user.

.PARAMETER SyncRoot
    Custom local sync directory. Defaults to C:\Users\$env:USERNAME\ZeroDrive.

.PARAMETER StartNow
    Immediately start the background sync service after installation.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ApiToken = $env:ZERODRIVE_API_TOKEN,

    [Parameter(Mandatory = $false)]
    [string]$SyncRoot = "$env:USERPROFILE\ZeroDrive",

    [Parameter(Mandatory = $false)]
    [switch]$StartNow = $true
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " ZeroDrive Windows Sync Client Installer" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Obtain and validate API Token
if ([string]::IsNullOrWhiteSpace($ApiToken)) {
    Write-Host "ZeroDrive API Token is required for authentication." -ForegroundColor Yellow
    $ApiToken = Read-Host "Please enter your ZeroDrive API Token (zd_sec_...)"
    if ([string]::IsNullOrWhiteSpace($ApiToken)) {
        Write-Host "No token provided. Using standard evaluation token." -ForegroundColor DarkYellow
        $ApiToken = "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633"
    }
}

# Persist user environment variable
[System.Environment]::SetEnvironmentVariable("ZERODRIVE_API_TOKEN", $ApiToken, [System.EnvironmentVariableTarget]::User)
$env:ZERODRIVE_API_TOKEN = $ApiToken
Write-Host "[Auth] API Token stored in User Environment." -ForegroundColor Green

# 2. Setup Sync Root Directory
$SyncRoot = [System.IO.Path]::GetFullPath($SyncRoot)
if (-not (Test-Path -LiteralPath $SyncRoot)) {
    New-Item -ItemType Directory -Path $SyncRoot -Force | Out-Null
}
Write-Host "[Folder] ZeroDrive sync folder ready: $SyncRoot" -ForegroundColor Green

# 3. Setup Script Installation Directory
$AppDir = "$env:LOCALAPPDATA\ZeroDrive"
if (-not (Test-Path -LiteralPath $AppDir)) {
    New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
}

$CurrentScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($CurrentScriptDir)) {
    $CurrentScriptDir = (Get-Location).Path
}

$DaemonSource = Join-Path $CurrentScriptDir "sync-daemon.ps1"
$DaemonDest = Join-Path $AppDir "sync-daemon.ps1"
if (Test-Path -LiteralPath $DaemonSource) {
    Copy-Item -LiteralPath $DaemonSource -Destination $DaemonDest -Force
}

$CsSource = Join-Path $CurrentScriptDir "zerodrive-sync.cs"
if (Test-Path -LiteralPath $CsSource) {
    Copy-Item -LiteralPath $CsSource -Destination (Join-Path $AppDir "zerodrive-sync.cs") -Force
}

$UpdaterSource = Join-Path $CurrentScriptDir "update-zerodrive.ps1"
if (Test-Path -LiteralPath $UpdaterSource) {
    Copy-Item -LiteralPath $UpdaterSource -Destination (Join-Path $AppDir "update-zerodrive.ps1") -Force
}

$ExeSource = Join-Path $CurrentScriptDir "zerodrive-sync.exe"
if (Test-Path -LiteralPath $ExeSource) {
    Copy-Item -LiteralPath $ExeSource -Destination (Join-Path $AppDir "zerodrive-sync.exe") -Force
}

$NotesSource = Join-Path $CurrentScriptDir "release-notes.json"
if (Test-Path -LiteralPath $NotesSource) {
    Copy-Item -LiteralPath $NotesSource -Destination (Join-Path $AppDir "release-notes.json") -Force
}

$ChangelogSource = Join-Path $CurrentScriptDir "CHANGELOG.md"
if (Test-Path -LiteralPath $ChangelogSource) {
    Copy-Item -LiteralPath $ChangelogSource -Destination (Join-Path $AppDir "CHANGELOG.md") -Force
}

# Create convenient shortcut helpers for checking updates and viewing changelog
Set-Content -LiteralPath (Join-Path $AppDir "ZeroDrive-CheckUpdates.cmd") -Value "@echo off`r`npowershell.exe -ExecutionPolicy Bypass -NoProfile -File `"%~dp0update-zerodrive.ps1`" -Trigger manual`r`npause`r`n" -Force
Set-Content -LiteralPath (Join-Path $AppDir "ZeroDrive-Changelog.cmd") -Value "@echo off`r`npowershell.exe -ExecutionPolicy Bypass -NoProfile -File `"%~dp0update-zerodrive.ps1`" -ShowChangelog`r`n" -Force

# Create config file
$config = @{
    sync_root = $SyncRoot
    api_base  = "https://api.zerodrive.dev"
    installed = (Get-Date).ToString("o")
    version   = "3.1.0"
} | ConvertTo-Json -Compress
Set-Content -LiteralPath (Join-Path $AppDir "config.json") -Value $config -Force
Write-Host "[Files] ZeroDrive engine installed to $AppDir" -ForegroundColor Green

# 4. Integrate with Windows Explorer Navigation Pane (CLSID Registration)
Write-Host "[Explorer] Registering ZeroDrive in File Explorer navigation pane..." -ForegroundColor Yellow
$Clsid = "{A4644062-094D-4A23-86B6-C9E62C88998D}"
$ClsidRoot = "HKCU:\Software\Classes\CLSID\$Clsid"

New-Item -Path $ClsidRoot -Force | Out-Null
Set-ItemProperty -Path $ClsidRoot -Name "(Default)" -Value "ZeroDrive" -Force
Set-ItemProperty -Path $ClsidRoot -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 1 -Force
Set-ItemProperty -Path $ClsidRoot -Name "SortOrderIndex" -Type DWord -Value 66 -Force

# InProcServer32
$InProcKey = "$ClsidRoot\InProcServer32"
New-Item -Path $InProcKey -Force | Out-Null
Set-ItemProperty -Path $InProcKey -Name "(Default)" -Value "$env:SystemRoot\System32\shell32.dll" -Force

# DefaultIcon (using Windows standard cloud icon)
$IconKey = "$ClsidRoot\DefaultIcon"
New-Item -Path $IconKey -Force | Out-Null
Set-ItemProperty -Path $IconKey -Name "(Default)" -Value "$env:SystemRoot\System32\imageres.dll,-1043" -Force

# Instance
$InstanceKey = "$ClsidRoot\Instance"
New-Item -Path $InstanceKey -Force | Out-Null
Set-ItemProperty -Path $InstanceKey -Name "CLSID" -Value "{0E5AAE11-A252-4c0d-AEE6-1B4CA014B6EC}" -Force

# Instance InitPropertyBag
$InitKey = "$InstanceKey\InitPropertyBag"
New-Item -Path $InitKey -Force | Out-Null
Set-ItemProperty -Path $InitKey -Name "Attributes" -Type DWord -Value 0x11 -Force
Set-ItemProperty -Path $InitKey -Name "TargetFolderPath" -Value $SyncRoot -Force

# ShellFolder
$ShellFolderKey = "$ClsidRoot\ShellFolder"
New-Item -Path $ShellFolderKey -Force | Out-Null
Set-ItemProperty -Path $ShellFolderKey -Name "Attributes" -Type DWord -Value 0xF080004D -Force
Set-ItemProperty -Path $ShellFolderKey -Name "FolderValueFlags" -Type DWord -Value 0x28 -Force
Set-ItemProperty -Path $ShellFolderKey -Name "PinToNameSpaceTree" -Value "" -Force

# Register under Desktop NameSpace
$NamespaceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"
New-Item -Path $NamespaceKey -Force | Out-Null
Set-ItemProperty -Path $NamespaceKey -Name "(Default)" -Value "ZeroDrive" -Force

# Register under Windows SyncRootManager
$SyncRootKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager\ZeroDrive!$env:USERNAME"
New-Item -Path $SyncRootKey -Force | Out-Null
Set-ItemProperty -Path $SyncRootKey -Name "DisplayName" -Value "ZeroDrive" -Force
Set-ItemProperty -Path $SyncRootKey -Name "UserSyncRoots" -Value $SyncRoot -Force
Set-ItemProperty -Path $SyncRootKey -Name "Icon" -Value "$env:SystemRoot\System32\imageres.dll,-1043" -Force

Write-Host "[Explorer] ZeroDrive pinned to File Explorer navigation pane." -ForegroundColor Green

# 5. Register Scheduled Task for Background Execution
Write-Host "[Service] Registering Windows Scheduled Task for automatic background sync..." -ForegroundColor Yellow

$TaskName = "ZeroDriveSync"
$TaskScript = Join-Path $AppDir "sync-daemon.ps1"
$VbsLauncher = Join-Path $AppDir "run-hidden.vbs"

# VBScript launcher ensures a completely invisible background window
$vbsContent = @"
Set objShell = CreateObject("Wscript.Shell")
strCommand = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File ""$TaskScript"" -SyncRoot ""$SyncRoot"""
objShell.Run strCommand, 0, False
"@
Set-Content -LiteralPath $VbsLauncher -Value $vbsContent -Force

# Unregister previous task if exists
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
} catch {}

$Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsLauncher`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                        -DontStopIfGoingOnBatteries `
                                        -ExecutionTimeLimit (New-TimeSpan -Days 365) `
                                        -RestartCount 5 `
                                        -RestartInterval (New-TimeSpan -Minutes 1) `
                                        -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName `
                       -Action $Action `
                       -Trigger $Trigger `
                       -Settings $Settings `
                       -Description "ZeroDrive Real-Time Cloud Files Sync Daemon" | Out-Null

Write-Host "[Service] Scheduled Task '$TaskName' registered (Runs invisibly at Logon)." -ForegroundColor Green

# 6. Launch now if requested
if ($StartNow) {
    Write-Host "[Service] Starting ZeroDrive background task now..." -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "[Service] ZeroDrive is running in the background." -ForegroundColor Green
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host " Installation Complete!" -ForegroundColor Green
Write-Host " ZeroDrive Folder : $SyncRoot" -ForegroundColor White
Write-Host " Open Windows File Explorer to see ZeroDrive in the sidebar." -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Green
