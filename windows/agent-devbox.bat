@echo off
REM Double-click launcher: installs the DEFAULT (multi-agent) agent-devbox.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-agent-devbox.ps1" -Variant agents
pause
