#!/usr/bin/env bash
# =============================================================================
# paseo-boot.sh — launch the paseo daemon as the non-root `paseo` user.
# Shared by Docker (docker-entrypoint.sh) and WSL (wsl-boot.sh). Runs as root.
#
# Refuses to start unless PASEO_PASSWORD is set (never expose the daemon open).
# Uses a single-instance lock so a re-entrant boot cannot spawn a second daemon.
# =============================================================================
set -euo pipefail

# The pidfile lives on the persistent data disk (/home/paseo/.paseo/paseo.pid), so it
# survives a WSL restart (and a container restart with a bind-mounted home). If the
# recorded PID is gone - or the PID was reused by an unrelated process - paseo would
# refuse to start with "Another Paseo daemon is already running" and the web UI would
# stay down for every following boot. Drop such a stale pidfile before starting.
clear_stale_pidfile() {
  local home="${PASEO_HOME:-/home/paseo/.paseo}"
  local pidfile="$home/paseo.pid"
  local pid=""
  [ -f "$pidfile" ] || return 0
  pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$pidfile" | head -n 1)"
  if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
    rm -f "$pidfile"
    echo "cleared stale paseo pidfile (pid=${pid:-unknown}, process is gone)"
    return 0
  fi
  if ! tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'paseo'; then
    rm -f "$pidfile"
    echo "cleared stale paseo pidfile (pid=$pid was reused by another process)"
  fi
  return 0
}

# Sourced by tests: define functions only (no side effects).
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

# The WSL `/etc/wsl.conf [boot]` command runs with a minimal PATH (often without
# /usr/bin), so `gosu` cannot resolve `env` and the daemon never starts. Pin a
# sane PATH and resolve the tools once; this is a no-op in Docker, where PATH is
# already complete (the existing value is appended, never dropped).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
GOSU_BIN="$(command -v gosu)" || { echo "FATAL: gosu not found in PATH" >&2; exit 1; }
ENV_BIN="$(command -v env)"   || { echo "FATAL: env not found in PATH" >&2; exit 1; }
SEED_BIN="$(command -v seed-agent-config.sh)" || { echo "FATAL: seed-agent-config.sh not found in PATH" >&2; exit 1; }

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
if [ -d /workspace ]; then chown "$PASEO_USER:$PASEO_USER" /workspace 2>/dev/null || true; fi

# Seed missing config as paseo.
"$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" HOME="$PASEO_HOME_DIR" "$SEED_BIN"

# Idempotent persisted settings (best-effort: daemon run also gets the env below).
if ! "$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" HOME="$PASEO_HOME_DIR" PASEO_HOME="$PASEO_HOME" \
  paseo daemon config set daemon.listen 0.0.0.0:6767 >/dev/null 2>&1; then
  echo "WARN: could not persist daemon.listen; PASEO_LISTEN=0.0.0.0:6767 still applies to this run."
fi
if ! "$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" HOME="$PASEO_HOME_DIR" PASEO_HOME="$PASEO_HOME" \
  paseo daemon config set features.webUi.enabled true >/dev/null 2>&1; then
  echo "WARN: could not persist features.webUi.enabled; PASEO_WEB_UI_ENABLED=true still applies to this run."
fi

# A dead/reused PID in the persisted pidfile must not block the daemon.
clear_stale_pidfile

# Foreground daemon as paseo, with the deployment env overrides.
exec "$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" \
  HOME="$PASEO_HOME_DIR" \
  PASEO_HOME="$PASEO_HOME" \
  PASEO_LISTEN="0.0.0.0:6767" \
  PASEO_WEB_UI_ENABLED="true" \
  PASEO_PASSWORD="$PASEO_PASSWORD" \
  paseo daemon run
