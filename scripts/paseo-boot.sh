#!/usr/bin/env bash
# =============================================================================
# paseo-boot.sh — launch the paseo daemon as the non-root `paseo` user.
# Shared by Docker (docker-entrypoint.sh) and WSL (wsl-boot.sh). Runs as root.
#
# Refuses to start unless PASEO_PASSWORD is set (never expose the daemon open).
# Uses a single-instance lock so a re-entrant boot cannot spawn a second daemon.
# =============================================================================
set -euo pipefail

PASEO_USER=paseo
PASEO_HOME_DIR=/home/paseo
export PASEO_HOME="$PASEO_HOME_DIR/.paseo"
export PASEO_LISTEN="${PASEO_LISTEN:-0.0.0.0:6767}"
export PASEO_WEB_UI_ENABLED="${PASEO_WEB_UI_ENABLED:-true}"

if [ -z "${PASEO_PASSWORD:-}" ]; then
  echo "FATAL: PASEO_PASSWORD is not set. Refusing to expose paseo without a password." >&2
  exit 1
fi

mkdir -p /run
exec 9>/run/agent-devbox-paseo.lock
if ! flock -n 9; then
  echo "paseo launcher is already running; nothing to do."
  exit 0
fi

# Fix ownership of the top-level homes only (never recurse the whole data disk).
chown "$PASEO_USER:$PASEO_USER" "$PASEO_HOME_DIR" 2>/dev/null || true
[ -d /workspace ] && chown "$PASEO_USER:$PASEO_USER" /workspace 2>/dev/null || true

# Seed missing config as paseo.
gosu "$PASEO_USER" env HOME="$PASEO_HOME_DIR" /usr/local/bin/seed-agent-config.sh

# Idempotent persisted settings (best-effort: daemon run also gets the env below).
gosu "$PASEO_USER" env HOME="$PASEO_HOME_DIR" PASEO_HOME="$PASEO_HOME" \
  paseo daemon config set daemon.listen 0.0.0.0:6767 >/dev/null 2>&1 || true
gosu "$PASEO_USER" env HOME="$PASEO_HOME_DIR" PASEO_HOME="$PASEO_HOME" \
  paseo daemon config set features.webUi.enabled true >/dev/null 2>&1 || true

# Foreground daemon as paseo, with the deployment env overrides.
exec gosu "$PASEO_USER" env \
  HOME="$PASEO_HOME_DIR" \
  PASEO_HOME="$PASEO_HOME" \
  PASEO_LISTEN="0.0.0.0:6767" \
  PASEO_WEB_UI_ENABLED="true" \
  PASEO_PASSWORD="$PASEO_PASSWORD" \
  paseo daemon run
