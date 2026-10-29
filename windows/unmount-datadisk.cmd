@echo off
REM Manual data-disk detach helper for agent-devbox (pure batch).
REM Usage (positional form):
REM   unmount-datadisk.cmd                          detach this folder's data.vhdx
REM   unmount-datadisk.cmd "D:\other\data.vhdx"     detach that VHDX
REM No admin/UAC needed. wsl --unmount takes the \\?\ device path.
REM
REM WSL returns -1 + Wsl/Service/DetachDisk/ERROR_FILE_NOT_FOUND when the disk
REM is not attached (e.g. right after a Windows reboot). That is a no-op, not a
REM failure: report [INFO] and exit 0. Real failures (disk in use, bad path)
REM still return non-zero.
REM Do NOT set WSL_UTF8: it makes --unmount fail with ERROR_INVALID_NAME even
REM for an attached disk. Redirected wsl output is UTF-16LE, so the detection
REM below matches both the UTF-16 dot pattern and the UTF-8/ANSI literal.
setlocal EnableExtensions
set "VHDX=%~1"
if not defined VHDX set "VHDX=%~dp0data.vhdx"
set "DEV=\\?\%VHDX%"
set "LOG=%~dp0datadisk-attach.log"
set "RC=1"

echo Detaching data disk: "%DEV%"
if not exist "%VHDX%" (
  echo [ERROR] VHDX not found: "%VHDX%"
  echo         Nothing to detach; check the path.
  >>"%LOG%" echo %DATE% %TIME% unmount "%VHDX%" state=missing
  goto :done
)

if not defined TEMP set "TEMP=%~dp0"
set "OUT=%TEMP%\agent-devbox-unmount-%RANDOM%-%RANDOM%.log"
wsl.exe --unmount "%DEV%" >"%OUT%" 2>&1
set "RC=%ERRORLEVEL%"

>>"%LOG%" echo %DATE% %TIME% unmount "%VHDX%" exit=%RC%
if exist "%OUT%" type "%OUT%" >>"%LOG%"

if %RC% EQU 0 (
  echo [OK] Data disk detached.
  goto :done
)

set "STATE=failed"
findstr /R /C:"E.R.R.O.R._.F.I.L.E._.N.O.T._.F.O.U.N.D" "%OUT%" >nul 2>&1
if not errorlevel 1 set "STATE=not-attached"
findstr /R /C:"0.x.8.0.0.7.0.0.0.2" "%OUT%" >nul 2>&1
if not errorlevel 1 set "STATE=not-attached"
findstr /C:"ERROR_FILE_NOT_FOUND" /C:"0x80070002" "%OUT%" >nul 2>&1
if not errorlevel 1 set "STATE=not-attached"
>>"%LOG%" echo %DATE% %TIME% unmount "%VHDX%" result=%STATE%

if "%STATE%"=="not-attached" (
  echo [INFO] Data disk is not attached ^(WSL: ERROR_FILE_NOT_FOUND^). Nothing to detach.
  set "RC=0"
  goto :done
)

echo.
echo [ERROR] Detach failed, exit code: %RC%.
echo Hint: the disk may already be detached or still in use by a distro.
echo       If it is already detached this is harmless; otherwise run
echo       wsl --terminate ^<distro^> and retry, then restart Windows if needed.
echo Log: "%LOG%"

:done
if exist "%OUT%" del /f /q "%OUT%" >nul 2>&1
echo.
pause
exit /b %RC%
