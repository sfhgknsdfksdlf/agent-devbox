@echo off
REM Double-click launcher: installs the LEAN base (agent-devbox-core).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-agent-devbox.ps1" -Variant core
pause
