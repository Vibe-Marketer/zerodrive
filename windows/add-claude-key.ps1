$key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINutSWnP7WZVtPHDB8+GIOW5JMJJub9wbwO/WXIdahgi claude-reelfarm-bridge"

# 1. Administrators authorized keys
$adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
if (Test-Path $adminKeys) {
    $content = Get-Content $adminKeys
    if ($content -notcontains $key) {
        Add-Content -Path $adminKeys -Value $key -Encoding UTF8
        Write-Host "Added key to $adminKeys"
    } else {
        Write-Host "Key already in $adminKeys"
    }
} else {
    Set-Content -Path $adminKeys -Value $key -Encoding UTF8
    Write-Host "Created $adminKeys with key"
}

# Lock ACLs strictly
& icacls.exe $adminKeys /inheritance:r /grant "BUILTIN\Administrators:F" /grant "NT AUTHORITY\SYSTEM:F"

# 2. User profile .ssh
$userPaths = @("C:\Users\andre\.ssh", "C:\Users\pc\.ssh")
foreach ($dir in $userPaths) {
    if (Test-Path $dir) {
        $userKey = Join-Path $dir "authorized_keys"
        if (Test-Path $userKey) {
            $userContent = Get-Content $userKey
            if ($userContent -notcontains $key) {
                Add-Content -Path $userKey -Value $key -Encoding UTF8
                Write-Host "Added key to $userKey"
            } else {
                Write-Host "Key already in $userKey"
            }
        } else {
            Set-Content -Path $userKey -Value $key -Encoding UTF8
            Write-Host "Created $userKey with key"
        }
    }
}

Write-Host "All keys installed successfully."
