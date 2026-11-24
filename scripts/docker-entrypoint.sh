#!/usr/bin/env bash
# =============================================================================
# docker-entrypoint.sh — Docker mode entrypoint (tini is PID 1).
# Runs as root, then hands off to paseo-boot.sh which drops the daemon to paseo.
#
# IS_DOCKER is baked as ENV IS_DOCKER=true in the image. `docker export` does
# not carry image ENV, so a WSL distro imported from the rootfs sees it unset
# and falls through to wsl-boot.sh.
# =============================================================================
set -euo pipefail

if [ "${IS_DOCKER:-false}" != "true" ]; then
  exec /usr/local/bin/wsl-boot.sh "$@"
fi

# Fail closed BEFORE any seed/chown/service start: prove /home, /root and
# /workspace really are the DATA_DIR bind mounts (and first-run init only after
# that). A wrong bind would otherwise write into the ephemeral layer.
/usr/local/bin/docker-data-preflight.sh

# Agent memory for root: one resident loopback service + missing-only assets.
# Best effort only — a memory failure must never block the container or paseo.
MEMORY_SUPERVISOR="${AGENT_DEVBOX_MEMORY_SUPERVISOR:-/usr/local/bin/memory-supervisor.sh}"
if [ -x "$MEMORY_SUPERVISOR" ]; then
  if ! "$MEMORY_SUPERVISOR" ensure 0 /root; then
    echo "WARN: agent memory (root) did not become healthy; continuing without it. See /run/agent-memory/0/service.log" >&2
  fi
else
  echo "WARN: $MEMORY_SUPERVISOR is missing; the root memory MCP is unavailable." >&2
fi

# Ownership (B3), the git safe.directory trust (B4) and the paseo memory service
# are all handled inside the shared paseo-boot.sh; this entrypoint only dispatches.
exec /usr/local/bin/paseo-boot.sh
