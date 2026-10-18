@echo off
REM Thin wrapper for mount-datadisk.ps1 (which self-elevates once).
REM ASCII only + CRLF. Usage:
REM   mount-datadisk.cmd                            attach .\data.vhdx (bare)
REM   mount-datadisk.cmd "D:\other\data.vhdx"       attach that VHDX (bare)
REM   mount-datadisk.cmd "D:\other\data.vhdx" NAME  attach + mount at /mnt/wsl/NAME
setlocal EnableExtensions
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mount-datadisk.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
endlocal & exit /b %RC%
