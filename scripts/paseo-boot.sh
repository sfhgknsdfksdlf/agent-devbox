#!/usr/bin/env bash
# =============================================================================
# paseo-boot.sh — launch the paseo daemon as the non-root `paseo` user.
# Shared by Docker (docker-entrypoint.sh) and WSL (wsl-boot.sh). Runs as root.
#
# Refuses to start unless PASEO_PASSWORD is set to a non-default value (never
# expose the daemon open, and never accept the retired public placeholder).
# Uses a single-instance lock so a re-entrant boot cannot spawn a second daemon.
# =============================================================================
set -euo pipefail

# Shared, pure parsers for PASEO_LISTEN / PASEO_WEB_UI_ENABLED. Resolve the
# sibling file without external tools so this also works when the whole
# scripts/ directory is copied to /usr/local/bin.
case "${BASH_SOURCE[0]}" in
  */*) _paseo_boot_dir="${BASH_SOURCE[0]%/*}" ;;
  *) _paseo_boot_dir="." ;;
esac
# shellcheck source=scripts/paseo-env.sh
. "$_paseo_boot_dir/paseo-env.sh"

# The Supervisor writes /home/paseo/.paseo/paseo.pid itself (compact JSON,
# no trailing newline) and the file survives a WSL/container restart. Only a
# lock proven dead, from an earlier boot, or held by a reused PID is dropped;
# a live Supervisor lock (or a briefly empty/partial write) is kept and never
# signalled.
_paseo_uid() {
  if [ -n "${AGENT_DEVBOX_PASEO_UID:-}" ]; then
    printf '%s\n' "$AGENT_DEVBOX_PASEO_UID"
    return 0
  fi
  id -u paseo 2>/dev/null
}

_paseo_node() {
  local bin
  if [ -n "${AGENT_DEVBOX_NODE_BIN:-}" ]; then
    bin="$AGENT_DEVBOX_NODE_BIN"
  else
    bin="$(command -v node 2>/dev/null)"
  fi
  [ -n "$bin" ] || return 1
  readlink -f "$bin" 2>/dev/null || printf '%s\n' "$bin"
}

_paseo_boot_id() {
  if [ -n "${AGENT_DEVBOX_BOOT_ID:-}" ]; then
    printf '%s\n' "$AGENT_DEVBOX_BOOT_ID"
    return 0
  fi
  [ -r /proc/sys/kernel/random/boot_id ] || return 1
  tr -d '\n' < /proc/sys/kernel/random/boot_id
}

# _paseo_lock_fields <pidfile>: six compact-JSON fields, unit-separator joined.
_paseo_lock_fields() {
  jq -er '
    select((.pid | type) == "number" and .pid > 0 and .pid == (.pid | floor))
    | [ (.pid | tostring), (.startedAt // ""), ((.uid // "") | tostring),
        (.bootId // ""), (.listen // ""), (.serverId // "") ]
    | join("\u001f")
  ' "$1" 2>/dev/null
}

# _paseo_lock_disposition <pid>: prints "live" or the stale reason.
# "live" is also returned for a live Supervisor whose JSON uid looks odd: the
# process identity wins, because deleting a live daemon's lock is worse than a
# later refusal. A PID that does not look like this image's Supervisor is reuse.
_paseo_lock_disposition() {
  local pid="$1" stat rest state ids uid_real uid_eff comm title exe node want_uid
  if [ ! -e "/proc/$pid" ]; then
    printf 'dead\n'
    return 0
  fi
  stat="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
  rest="${stat##*) }"
  state="${rest%% *}"
  if [ -z "$stat" ] || [ "$state" = "Z" ]; then
    printf 'dead\n'
    return 0
  fi
  ids="$(awk '/^Uid:/ {print $2 " " $3; exit}' "/proc/$pid/status" 2>/dev/null || true)"
  uid_real="${ids%% *}"
  uid_eff="${ids##* }"
  comm="$(tr -d '\n' 2>/dev/null < "/proc/$pid/comm" || true)"
  title="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | sed -n '1p' || true)"
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
  exe="${exe% (deleted)}"
  node="$(_paseo_node || true)"
  want_uid="$(_paseo_uid || true)"
  if [ -z "$exe" ] || [ "$exe" != "$node" ] || [ "$comm" != "Paseo Superviso" ] || [ "$title" != "Paseo Supervisor" ]; then
    printf 'reused\n'
    return 0
  fi
  if [ -z "$want_uid" ] || [ "$uid_real" != "$want_uid" ] || [ "$uid_eff" != "$want_uid" ]; then
    printf 'live\n'
    return 0
  fi
  printf 'live\n'
}

clear_stale_pidfile() {
  local home="${PASEO_HOME:-/home/paseo/.paseo}"
  local pidfile="$home/paseo.pid"
  local raw line pid startedAt juid jboot listen serverId cur_boot reason
  [ -f "$pidfile" ] || return 0
  raw="$(cat "$pidfile" 2>/dev/null)" || {
    echo "kept paseo pidfile (unreadable)"
    return 0
  }
  if [ -z "$raw" ]; then
    echo "kept empty paseo pidfile (supervisor may still be writing it)"
    return 0
  fi
  if ! line="$(_paseo_lock_fields "$pidfile")"; then
    echo "kept paseo pidfile (not a complete Supervisor lock yet)"
    return 0
  fi
  IFS=$'\x1f' read -r pid startedAt juid jboot listen serverId <<< "$line"
  cur_boot="$(_paseo_boot_id || true)"
  reason=""
  if [ -n "$jboot" ] && [ -n "$cur_boot" ] && [ "$jboot" != "$cur_boot" ]; then
    reason="cross-boot"
  else
    reason="$(_paseo_lock_disposition "$pid")"
  fi
  if [ "$reason" = "live" ]; then
    return 0
  fi
  # Re-read: only delete a lock that did not change while it was judged.
  if [ "$(cat "$pidfile" 2>/dev/null || true)" != "$raw" ]; then
    echo "kept paseo pidfile (changed while checking)"
    return 0
  fi
  rm -f "$pidfile"
  echo "cleared stale paseo pidfile (pid=$pid startedAt=$startedAt uid=$juid bootId=$jboot listen=$listen serverId=$serverId, $reason)"
  return 0
}

# Sourced by tests: define functions only (no side effects).
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

# Parse the deployment env ONCE, before any lock/seed/config/daemon side effect.
if ! paseo_parse_listen "${PASEO_LISTEN:-0.0.0.0:6767}"; then
  echo "FATAL: invalid PASEO_LISTEN; expected host:port such as 0.0.0.0:6767 or [::1]:6767." >&2
  exit 1
fi
if ! paseo_parse_web_ui "${PASEO_WEB_UI_ENABLED:-true}"; then
  echo "FATAL: invalid PASEO_WEB_UI_ENABLED; expected true|false|1|0." >&2
  exit 1
fi
export PASEO_LISTEN="$PASEO_LISTEN_CANONICAL"
export PASEO_WEB_UI_ENABLED="$PASEO_WEB_UI_CANONICAL"

# The WSL `/etc/wsl.conf [boot]` command runs with a minimal PATH (often without
# /usr/bin), so `gosu` cannot resolve `env` and the daemon never starts. Pin a
# sane PATH and resolve the tools once; this is a no-op in Docker, where PATH is
# already complete (the existing value is appended, never dropped).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
GOSU_BIN="${AGENT_DEVBOX_GOSU_BIN:-$(command -v gosu)}" || { echo "FATAL: gosu not found in PATH" >&2; exit 1; }
ENV_BIN="$(command -v env)"   || { echo "FATAL: env not found in PATH" >&2; exit 1; }
SEED_BIN="${AGENT_DEVBOX_SEED_BIN:-$(command -v seed-agent-config.sh)}" || { echo "FATAL: seed-agent-config.sh not found in PATH" >&2; exit 1; }

PASEO_USER=paseo
PASEO_HOME_DIR=/home/paseo
export PASEO_HOME="${AGENT_DEVBOX_PASEO_HOME:-$PASEO_HOME_DIR/.paseo}"
PASEO_LOCK_DIR="${AGENT_DEVBOX_PASEO_LOCK_DIR:-/run}"

if [ -z "${PASEO_PASSWORD:-}" ]; then
  echo "FATAL: PASEO_PASSWORD is not set. Refusing to expose paseo without a password." >&2
  exit 1
fi
if [ "$PASEO_PASSWORD" = "change-me-please" ]; then
  echo "FATAL: PASEO_PASSWORD is still the retired public default placeholder. Choose your own password; refusing to start." >&2
  exit 1
fi

mkdir -p "$PASEO_LOCK_DIR"
exec 9>"$PASEO_LOCK_DIR/agent-devbox-paseo.lock"
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
  paseo daemon config set daemon.listen "$PASEO_LISTEN" >/dev/null 2>&1; then
  echo "WARN: could not persist daemon.listen; PASEO_LISTEN=$PASEO_LISTEN still applies to this run."
fi
if ! "$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" HOME="$PASEO_HOME_DIR" PASEO_HOME="$PASEO_HOME" \
  paseo daemon config set features.webUi.enabled "$PASEO_WEB_UI_ENABLED" >/dev/null 2>&1; then
  echo "WARN: could not persist features.webUi.enabled; PASEO_WEB_UI_ENABLED=$PASEO_WEB_UI_ENABLED still applies to this run."
fi

# A dead/reused PID in the persisted pidfile must not block the daemon.
clear_stale_pidfile

# Foreground daemon as paseo, with the deployment env overrides.
exec "$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" \
  HOME="$PASEO_HOME_DIR" \
  PASEO_HOME="$PASEO_HOME" \
  PASEO_LISTEN="$PASEO_LISTEN" \
  PASEO_WEB_UI_ENABLED="$PASEO_WEB_UI_ENABLED" \
  PASEO_PASSWORD="$PASEO_PASSWORD" \
  paseo daemon run
