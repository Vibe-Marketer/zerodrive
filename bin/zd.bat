@echo off
set "VAULT=primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f"
set "RCLONE=C:\Users\andre\.zerodrive\bin\rclone.exe"

if "%~1"=="status" goto do_status
if "%~1"=="ls" goto do_ls
if "%~1"=="list" goto do_ls
if "%~1"=="size" goto do_size
if "%~1"=="mount" goto do_mount
if "%~1"=="doctor" goto do_doctor
if "%~1"=="" goto do_help
if "%~1"=="help" goto do_help

"%RCLONE%" %*
goto end

:do_status
echo.
echo   ZeroDrive Windows Status
echo ======================================================
echo   Mount Folder: C:\Users\andre\ZeroDrive
"%RCLONE%" size "%VAULT%"
goto end

:do_ls
if "%~2"=="" goto ls_root
"%RCLONE%" lsd "%VAULT%/%~2"
"%RCLONE%" lsl "%VAULT%/%~2" --max-depth 1
goto end

:ls_root
"%RCLONE%" lsd "%VAULT%"
"%RCLONE%" lsl "%VAULT%" --max-depth 1
goto end

:do_size
if "%~2"=="" goto size_root
"%RCLONE%" size "%VAULT%/%~2"
goto end

:size_root
"%RCLONE%" size "%VAULT%"
goto end

:do_doctor
echo.
echo   ZeroDrive Doctor (NAEGELE-PC)
echo ======================================================
echo 1. Rclone Version:
"%RCLONE%" version
echo.
echo 2. Cloud Vault Connection:
"%RCLONE%" lsd "%VAULT%"
goto end

:do_mount
start "" /b "%RCLONE%" mount "%VAULT%" C:\Users\andre\ZeroDrive --vfs-cache-mode full --vfs-links --dir-cache-time 72h
goto end

:do_help
echo ZeroDrive Windows CLI (zd)
echo Commands: status, ls, size, mount, doctor
goto end

:end
