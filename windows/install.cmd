@echo off
REM agent-devbox Windows bootstrapper.
REM ASCII-only. Fetches the installer scripts from the project SOURCE (main) and
REM runs them; the GitHub Release is used ONLY for the rootfs image payload.
REM Downloads use PowerShell (Invoke-WebRequest) so the Windows system proxy / VPN
REM is honoured automatically - the curl CLI ignores the system proxy.
setlocal EnableExtensions
chcp 65001 >nul

set "REPO=sfhgknsdfksdlf/agent-devbox"
set "RAW=https://raw.githubusercontent.com/%REPO%/main/windows"
set "REQUESTED=%AGENT_DEVBOX_RELEASE_TAG%"

set "BASE=%LOCALAPPDATA%\agent-devbox"
if not exist "%BASE%" mkdir "%BASE%" >nul 2>&1
set "STAGE=%BASE%\bootstrap-%RANDOM%%RANDOM%"
mkdir "%STAGE%" >nul 2>&1
if not exist "%STAGE%" (
  echo [ERROR] Cannot create the staging directory: "%STAGE%"
  pause
  exit /b 1
)

echo Fetching installer scripts from the project source main ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; foreach ($f in 'wsl-ensure.ps1','wsl-ensure-downloads.ps1','install-agent-devbox.ps1','mount-datadisk.ps1','mount-datadisk.cmd','unmount-datadisk.ps1','unmount-datadisk.cmd') { Invoke-WebRequest -Uri ('%RAW%/' + $f) -OutFile (Join-Path '%STAGE%' $f) -UseBasicParsing }"
if errorlevel 1 goto :fetch_failed

if not exist "%STAGE%\install-agent-devbox.ps1" goto :missing_installer

echo Starting the installer ...
if defined REQUESTED (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%STAGE%\install-agent-devbox.ps1" -ReleaseTag "%REQUESTED%" %*
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%STAGE%\install-agent-devbox.ps1" %*
)
set "RC=%ERRORLEVEL%"

rmdir /s /q "%STAGE%" >nul 2>&1
echo.
if "%RC%"=="0" goto :run_ok
echo [ERROR] agent-devbox install failed (exit code %RC%).
goto :run_end
:run_ok
echo [OK] agent-devbox install finished. Enter the environment with: wsl -d agent-devbox  OR  wsl -d agent-devbox-core
:run_end
echo.
pause
endlocal & exit /b %RC%

:fetch_failed
echo [ERROR] Could not fetch the installer scripts from %RAW%.
echo         Check your network / VPN, or set an explicit tag before running, e.g.:
echo             set AGENT_DEVBOX_RELEASE_TAG=beta-20261018.1559
goto :fail

:missing_installer
echo [ERROR] The installer script is missing after download.
goto :fail

:fail
rmdir /s /q "%STAGE%" >nul 2>&1
echo.
pause
endlocal & exit /b 1
