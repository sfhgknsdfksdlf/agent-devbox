@echo off
REM Thin wrapper for unmount-datadisk.ps1 (which self-elevates once).
REM ASCII only + CRLF. Usage:
REM   unmount-datadisk.cmd                          detach .\data.vhdx
REM   unmount-datadisk.cmd "D:\other\data.vhdx"     detach that VHDX
setlocal EnableExtensions
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0unmount-datadisk.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
endlocal & exit /b %RC%
