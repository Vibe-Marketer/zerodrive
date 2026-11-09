<#
.SYNOPSIS
    ZeroDrive Windows Uninstaller
    Removes Scheduled Task, unregisters Explorer sidebar CLSID, and cleans registry settings.

.PARAMETER KeepFiles
    Preserve local files in the ZeroDrive folder (defaults to true).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$KeepFiles = $true
)

$ErrorActionPreference = "Continue"
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " ZeroDrive Windows Sync Client Uninstaller" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Stop and remove Scheduled Task
$TaskName = "ZeroDriveSync"
Write-Host "[Service] Stopping and unregistering Scheduled Task '$TaskName'..." -ForegroundColor Yellow
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[Service] Scheduled Task removed." -ForegroundColor Green
} catch {
    Write-Host "[Service] Task not registered or already removed." -ForegroundColor DarkGray
}

# 2. Terminate running background PowerShell sync instances
Write-Host "[Process] Stopping background sync processes..." -ForegroundColor Yellow
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*sync-daemon.ps1*" } | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# 3. Remove Registry CLSID and Explorer Sidebar Entry
Write-Host "[Explorer] Removing ZeroDrive from Windows Explorer navigation pane..." -ForegroundColor Yellow
$Clsid = "{A4644062-094D-4A23-86B6-C9E62C88998D}"
$ClsidRoot = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespaceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"
$SyncRootKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager\ZeroDrive!$env:USERNAME"

if (Test-Path -Path $NamespaceKey) { Remove-Item -Path $NamespaceKey -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -Path $ClsidRoot) { Remove-Item -Path $ClsidRoot -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -Path $SyncRootKey) { Remove-Item -Path $SyncRootKey -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "[Explorer] Explorer navigation pane registry keys removed." -ForegroundColor Green

# 4. Clean up LocalAppData scripts
$AppDir = "$env:LOCALAPPDATA\ZeroDrive"
if (Test-Path -LiteralPath $AppDir) {
    Remove-Item -LiteralPath $AppDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[Files] ZeroDrive application directory removed." -ForegroundColor Green
}

if (-not $KeepFiles) {
    $SyncRoot = "$env:USERPROFILE\ZeroDrive"
    if (Test-Path -LiteralPath $SyncRoot) {
        Remove-Item -LiteralPath $SyncRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[Files] ZeroDrive sync folder deleted: $SyncRoot" -ForegroundColor Yellow
    }
} else {
    Write-Host "[Files] Local files preserved in user folder." -ForegroundColor Green
}

Write-Host "==========================================================" -ForegroundColor Green
Write-Host " ZeroDrive has been cleanly uninstalled from Windows." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
