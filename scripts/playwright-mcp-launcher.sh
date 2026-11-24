#!/usr/bin/env bash
# Playwright MCP launcher: the ONLY place Chromium runs with --no-sandbox.
#
# The managed OpenCode config (config/opencode/global-mcp.json → /etc/opencode)
# starts `playwright-mcp` through this wrapper. Two reasons:
#   1. the MCP server is spawned by the paseo daemon (uid `paseo`), but an
#      interactive root shell can also trigger it — drop to `paseo` first so the
#      MCP never runs as root;
#   2. the shared Chromium tree is root-owned and the container commonly runs
#      without a user namespace, so THIS process needs --no-sandbox. The flag is
#      deliberately wrapper-scoped: it must never become a global ENV (that
#      would weaken every other Chromium/Playwright invocation in the image).
set -euo pipefail

ID_BIN="${AGENT_DEVBOX_ID_BIN:-id}"
PLAYWRIGHT_MCP_BIN=/usr/local/bin/playwright-mcp

if [ "$("$ID_BIN" -u)" -eq 0 ] && command -v gosu >/dev/null 2>&1; then
  exec gosu paseo env HOME=/home/paseo "$PLAYWRIGHT_MCP_BIN" \
    --headless --isolated \
    --executable-path /usr/local/bin/chromium --no-sandbox "$@"
fi

exec "$PLAYWRIGHT_MCP_BIN" \
  --headless --isolated \
  --executable-path /usr/local/bin/chromium --no-sandbox "$@"
