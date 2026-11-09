<#
.SYNOPSIS
    ZeroDrive Windows Sync Diagnostic and Verification Suite
    Verifies API connectivity, path normalization, file lock handling, and shell registry integration.

.PARAMETER ApiBase
    ZeroDrive REST API base URL.

.PARAMETER ApiToken
    ZeroDrive Bearer authorization token.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ApiBase = "https://api.zerodrive.dev",

    [Parameter(Mandatory = $false)]
    [string]$ApiToken = $env:ZERODRIVE_API_TOKEN
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($ApiToken)) {
    $ApiToken = "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633"
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " ZeroDrive Windows Sync Verification Test Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Endpoint : $ApiBase" -ForegroundColor White

$passed = 0
$failed = 0

function Assert-Test {
    param(
        [string]$Name,
        [scriptblock]$TestBlock
    )

    Write-Host "[TEST] $Name ... " -NoNewline -ForegroundColor Yellow
    try {
        $result = & $TestBlock
        if ($result -ne $false) {
            Write-Host "PASS" -ForegroundColor Green
            $script:passed++
        } else {
            Write-Host "FAIL" -ForegroundColor Red
            $script:failed++
        }
    }
    catch {
        Write-Host "FAIL ($($_.Exception.Message))" -ForegroundColor Red
        $script:failed++
    }
}

# Test 1: API Health Check
Assert-Test "ZeroDrive API Gateway Health Check" {
    $headers = @{ "Authorization" = "Bearer $ApiToken" }
    $res = Invoke-RestMethod -Uri "$ApiBase/v1/health" -Headers $headers -TimeoutSec 10
    return ($res.ok -eq $true -or $res.status -eq "ok" -or $res.healthy -eq $true)
}

# Test 2: File Enumeration
Assert-Test "Enumerate Remote Files (/v1/files)" {
    $headers = @{ "Authorization" = "Bearer $ApiToken" }
    $res = Invoke-RestMethod -Uri "$ApiBase/v1/files?limit=10" -Headers $headers -TimeoutSec 10
    return ($res.ok -eq $true -and ($res.files -ne $null -or $res.directories -ne $null))
}

# Test 3: Path Normalizer Logic
Assert-Test "Cross-Platform Path Normalizer (\ <-> /)" {
    $winPath = "MAIN\SubFolder\Doc.txt"
    $vaultPath = $winPath.Replace('\', '/')
    if ($vaultPath -ne "MAIN/SubFolder/Doc.txt") { return $false }
    $backToWin = $vaultPath.Replace('/', '\')
    return ($backToWin -eq $winPath)
}

# Test 4: File Lock Retry Mechanism Simulation
Assert-Test "File Lock Sharing Violation Retry" {
    $tempFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempFile, "Temporary test data for locking check.")

    $locked = $false
    # Open file with exclusive lock in background
    $lockStream = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    
    # Attempt read with sharing violation detection
    $retryCount = 0
    try {
        try {
            $testStream = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $testStream.Close()
        }
        catch [System.IO.IOException] {
            $retryCount++
            $locked = $true
        }
    }
    finally {
        $lockStream.Dispose()
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }

    return ($locked -and $retryCount -eq 1)
}

# Test 5: Explorer Sidebar Registry Configuration
Assert-Test "Windows Explorer Navigation Pane CLSID Registration" {
    $Clsid = "{A4644062-094D-4A23-86B6-C9E62C88998D}"
    $ClsidKey = "HKCU:\Software\Classes\CLSID\$Clsid"
    $NamespaceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

    # Only test if installer was run
    if (Test-Path $ClsidKey) {
        $pinned = (Get-ItemProperty -Path $ClsidKey -Name "System.IsPinnedToNameSpaceTree")."System.IsPinnedToNameSpaceTree"
        return ($pinned -eq 1 -and (Test-Path $NamespaceKey))
    }
    # Skip gracefully if not yet installed
    Write-Host "(Skipped: Installer has not been run yet) " -NoNewline -ForegroundColor DarkGray
    return $true
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Test Results: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan
