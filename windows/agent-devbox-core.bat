@echo off
REM Double-click launcher: installs the LEAN base (agent-devbox-core).
setlocal
chcp 65001 >nul

REM Self-elevate once (UAC). The elevated copy passes fltmc and does the work.
fltmc >nul 2>&1
if not errorlevel 1 goto :elevated

set "AGENT_DEVBOX_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath $env:AGENT_DEVBOX_SELF -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Elevation cancelled.' -ForegroundColor Yellow; Read-Host 'Press Enter to close' }"
exit /b

:elevated
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-agent-devbox.ps1" -Variant core
if errorlevel 1 (
  echo.
  echo [ERROR] agent-devbox install failed. See the messages above.
) else (
  echo.
  echo [OK] agent-devbox install finished. Enter the environment with: wsl -d agent-devbox-core
)
echo.
pause
endlocal
