#!/usr/bin/env bash
# mcp-dap-server launcher: drop root to `paseo` before starting the DAP MCP.
#
# The managed OpenCode config (config/opencode/global-mcp.json → /etc/opencode)
# starts this adapter. When the daemon spawns it the current user already is
# `paseo`; when an interactive root shell spawns it, gosu restores the service
# identity so the MCP never runs as root. No extra flags: the delve adapter
# takes its own argv, which is forwarded unchanged.
set -euo pipefail

ID_BIN="${AGENT_DEVBOX_ID_BIN:-id}"
MCP_DAP_BIN=/usr/local/bin/mcp-dap-server

if [ "$("$ID_BIN" -u)" -eq 0 ] && command -v gosu >/dev/null 2>&1; then
  exec gosu paseo env HOME=/home/paseo "$MCP_DAP_BIN" "$@"
fi

exec "$MCP_DAP_BIN" "$@"
