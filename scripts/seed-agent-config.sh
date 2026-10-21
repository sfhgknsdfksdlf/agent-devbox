#!/usr/bin/env bash
# =============================================================================
# seed-agent-config.sh — copy the build-time seed (/opt/agent-seed) into $HOME,
# ONLY when a file is missing (never overwrite user config). Run as the TARGET
# user so newly created files are owned by them.
# =============================================================================
set -euo pipefail

SEED="${AGENT_SEED_DIR:-/opt/agent-seed}"
[ -d "$SEED" ] || exit 0
: "${HOME:?seed-agent-config.sh requires HOME to be set}"

for rel in ".config/opencode" ".omo"; do
  if [ -d "$SEED/$rel" ]; then
    mkdir -p "$HOME/$rel"
    cp -rn "$SEED/$rel/." "$HOME/$rel/"
  fi
done
