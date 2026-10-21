#!/usr/bin/env bash
# =============================================================================
# agent-env.sh — shared environment for agent-devbox (Docker AND WSL).
# Sourced by login shells (via /etc/profile.d/agent-devbox.sh) and by launchers.
# Deliberately does NOT set HOME (the WSL root shell must keep HOME=/root).
# =============================================================================
export GOROOT=/usr/local/go
export GOPATH="${GOPATH:-$HOME/go}"
export GOCACHE="${GOCACHE:-$HOME/.cache/go-build}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/ms-playwright}"
export CHROME_PATH="${CHROME_PATH:-/usr/local/bin/chromium}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export PATH="/usr/local/go/bin:$GOPATH/bin:/usr/local/bin:$PATH"
