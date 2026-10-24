@echo off
REM Manual data-disk attach helper for agent-devbox (pure batch).
REM Usage (positional form):
REM   mount-datadisk.cmd                          attach this folder's data.vhdx (bare)
REM   mount-datadisk.cmd "D:\other\data.vhdx"     attach that VHDX (bare)
REM Bare attach only: WSL gets the raw disk and the guest boot script mounts it by UUID.
REM No admin/UAC needed: wsl --mount --vhd --bare works for a normal user.
setlocal EnableExtensions
set "VHDX=%~1"
if not defined VHDX set "VHDX=%~dp0data.vhdx"
set "RC=1"
if not exist "%VHDX%" goto :missing
echo Attaching data disk: "%VHDX%"
for /l %%i in (1,1,3) do (
  call :one %%i
  if not errorlevel 1 goto :attached
)
goto :failed

:one
wsl.exe --mount --vhd "%VHDX%" --bare
set "RC=%ERRORLEVEL%"
>>"%~dp0datadisk-attach.log" echo %DATE% %TIME% attempt %1 exit=%RC%
if %RC% NEQ 0 if %1 LSS 3 (
  echo attempt %1 failed ^(exit %RC%^), retrying in 2 seconds...
  ping -n 3 127.0.0.1 >nul
)
exit /b %RC%

:attached
echo.
echo [OK] Data disk attached. Next step:
echo   wsl --terminate ^<distro^>
echo then reopen the distro; its boot script will mount the disk.
goto :done

:failed
echo.
echo [ERROR] Attach failed, exit code: %RC%.
echo Hint: 255 / 0x80040312 usually means the disk is ALREADY attached.
echo       In that case just run: wsl --terminate ^<distro^>  and reopen the distro.
echo Log: "%~dp0datadisk-attach.log"
goto :done

:missing
echo [ERROR] VHDX not found: "%VHDX%"
echo Usage: mount-datadisk.cmd ["D:\other\data.vhdx"]
echo.

:done
echo.
pause
exit /b %RC%
