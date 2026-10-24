@echo off
REM Manual data-disk detach helper for agent-devbox (pure batch).
REM Usage (positional form):
REM   unmount-datadisk.cmd                          detach this folder's data.vhdx
REM   unmount-datadisk.cmd "D:\other\data.vhdx"     detach that VHDX
REM No admin/UAC needed. wsl --unmount takes the \\?\ device path.
setlocal EnableExtensions
set "VHDX=%~1"
if not defined VHDX set "VHDX=%~dp0data.vhdx"
set "DEV=\\?\%VHDX%"
echo Detaching data disk: "%DEV%"
wsl.exe --unmount "%DEV%"
set "RC=%ERRORLEVEL%"
>>"%~dp0datadisk-attach.log" echo %DATE% %TIME% unmount "%VHDX%" exit=%RC%
if %RC% NEQ 0 (
  echo.
  echo [ERROR] Detach failed, exit code: %RC%.
  echo Hint: the disk may already be detached, or a distro is still using it.
  echo       Run wsl --terminate ^<distro^> and retry; if it still fails, restart Windows.
  echo Log: "%~dp0datadisk-attach.log"
) else (
  echo [OK] Data disk detached.
)
echo.
pause
exit /b %RC%
