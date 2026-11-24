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

_paseo_gid() {
  if [ -n "${AGENT_DEVBOX_PASEO_GID:-}" ]; then
    printf '%s\n' "$AGENT_DEVBOX_PASEO_GID"
    return 0
  fi
  id -g paseo 2>/dev/null
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

# ensure_owned_dir <path> <label> <fatal|warn>: chown ONLY the directory itself
# (never recurse the data disk), then re-stat and require the exact numeric
# owner. `fatal` refuses to start (paseo home); `warn` continues (workspace).
ensure_owned_dir() {
  local path="$1" label="$2" severity="$3" want current
  want="$PASEO_UID:$PASEO_GID"
  if [ ! -d "$path" ]; then
    if [ "$severity" = fatal ]; then
      echo "FATAL: $label $path is missing; refusing to start." >&2
      return 1
    fi
    echo "WARN: $label $path is missing; skipping ownership check." >&2
    return 0
  fi
  if ! current="$("$STAT_BIN" -c '%u:%g' -- "$path")"; then
    if [ "$severity" = fatal ]; then
      echo "FATAL: could not read the owner of $label $path; refusing to start." >&2
      return 1
    fi
    echo "WARN: could not read the owner of $label $path; skipping." >&2
    return 0
  fi
  if [ "$current" = "$want" ]; then
    echo "$label $path is already owned by $want; no change."
    return 0
  fi
  if ! "$CHOWN_BIN" "$want" -- "$path"; then
    if [ "$severity" = fatal ]; then
      echo "FATAL: could not chown $label $path to $want; refusing to start." >&2
      return 1
    fi
    echo "WARN: could not chown $label $path to $want; continuing." >&2
    return 0
  fi
  current="unknown"
  if ! current="$("$STAT_BIN" -c '%u:%g' -- "$path")"; then
    current="unknown"
  fi
  if [ "$current" != "$want" ]; then
    if [ "$severity" = fatal ]; then
      echo "FATAL: $label $path is owned by $current, expected $want; refusing to start." >&2
      return 1
    fi
    echo "WARN: $label $path is owned by $current, expected $want; continuing." >&2
    return 0
  fi
  echo "chowned $label $path to $want."
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
STAT_BIN="${AGENT_DEVBOX_STAT_BIN:-$(command -v stat)}" || { echo "FATAL: stat not found in PATH" >&2; exit 1; }
CHOWN_BIN="${AGENT_DEVBOX_CHOWN_BIN:-$(command -v chown)}" || { echo "FATAL: chown not found in PATH" >&2; exit 1; }
FLOCK_BIN="${AGENT_DEVBOX_FLOCK_BIN:-$(command -v flock)}" || { echo "FATAL: flock not found in PATH" >&2; exit 1; }

PASEO_USER=paseo
PASEO_HOME_DIR="${AGENT_DEVBOX_PASEO_HOME_DIR:-/home/paseo}"
WORKSPACE_DIR="${AGENT_DEVBOX_WORKSPACE_DIR:-/workspace}"
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
# util-linux exits 75 on a held lock (`-E 75`); any other rc is a real error.
if "$FLOCK_BIN" -n -E 75 9; then
  :
else
  rc=$?
  if [ "$rc" -eq 75 ]; then
    echo "paseo launcher is already running; nothing to do."
    exit 0
  fi
  echo "FATAL: could not acquire the paseo launcher lock (rc=$rc); refusing to start." >&2
  exit 1
fi

PASEO_UID="$(_paseo_uid || true)"
PASEO_GID="$(_paseo_gid || true)"
if [ -z "$PASEO_UID" ] || [ -z "$PASEO_GID" ]; then
  echo "FATAL: could not resolve the paseo uid/gid; refusing to start." >&2
  exit 1
fi
ensure_owned_dir "$PASEO_HOME_DIR" "paseo home" fatal || exit 1
ensure_owned_dir "$WORKSPACE_DIR" "workspace" warn

# Trust /workspace for the service user's git in BOTH modes (Docker + WSL).
# Always run as paseo with paseo's own HOME so root's global git config is never
# touched, read the existing entries first, and add only when the exact line is
# missing (never --replace-all / never drop other entries). Best-effort: a
# missing git or any git failure only warns and never blocks startup.
GIT_BIN="${AGENT_DEVBOX_GIT_BIN:-$(command -v git 2>/dev/null || true)}"
GIT_SAFE_DIR=/workspace
if [ -z "$GIT_BIN" ]; then
  echo "WARN: git not found; skipping $GIT_SAFE_DIR safe.directory setup." >&2
else
  git_safe_dirs=""
  git_rc=0
  git_safe_dirs="$("$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" HOME="$PASEO_HOME_DIR" \
    "$GIT_BIN" config --global --get-all safe.directory 2>/dev/null)" || git_rc=$?
  if [ "$git_rc" -ne 0 ]; then
    # git exits 1 when the key is unset; anything else is a real read failure.
    if [ "$git_rc" -ne 1 ]; then
      echo "WARN: could not read git safe.directory (git rc=$git_rc); continuing." >&2
    fi
    git_safe_dirs=""
  fi
  if grep -Fxq -- "$GIT_SAFE_DIR" <<< "$git_safe_dirs"; then
    echo "$GIT_SAFE_DIR is already a trusted git directory; no change."
  elif ! "$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" HOME="$PASEO_HOME_DIR" \
      "$GIT_BIN" config --global --add safe.directory "$GIT_SAFE_DIR"; then
    echo "WARN: could not add $GIT_SAFE_DIR to git safe.directory; continuing." >&2
  else
    echo "added $GIT_SAFE_DIR to git safe.directory for $PASEO_USER."
  fi
fi

# Seed missing config as paseo.
"$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" HOME="$PASEO_HOME_DIR" "$SEED_BIN"

# Agent memory for the daemon's user: start/reuse the resident service and
# install its missing-only OpenCode assets before the daemon inherits the env.
# Docker has no external boot deadline, so it may wait for the first-run model
# download; WSL has a 30s service deadline / 90s installer budget, so it only
# waits briefly and the endpoint is published on the next ensure (next boot).
MEMORY_SUPERVISOR="${AGENT_DEVBOX_MEMORY_SUPERVISOR:-$(command -v memory-supervisor.sh 2>/dev/null || true)}"
MEMORY_ENV="${AGENT_DEVBOX_MEMORY_ENV:-$(command -v memory-env.sh 2>/dev/null || true)}"
if [ "${IS_DOCKER:-false}" = "true" ]; then
  MEMORY_HEALTH_TIMEOUT="${AGENT_DEVBOX_MEMORY_HEALTH_TIMEOUT:-180}"
else
  MEMORY_HEALTH_TIMEOUT="${AGENT_DEVBOX_PASEO_MEMORY_HEALTH_TIMEOUT:-8}"
fi
if [ -n "$MEMORY_SUPERVISOR" ] && [ -x "$MEMORY_SUPERVISOR" ]; then
  if ! AGENT_DEVBOX_MEMORY_HEALTH_TIMEOUT="$MEMORY_HEALTH_TIMEOUT" \
    "$MEMORY_SUPERVISOR" ensure "$PASEO_UID" "$PASEO_HOME_DIR"; then
    echo "WARN: agent memory (uid $PASEO_UID) did not become healthy; continuing without it." >&2
  fi
else
  echo "WARN: memory-supervisor.sh not found; continuing without the memory MCP." >&2
fi

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

# The daemon's OpenCode children inherit this process env, so publish the memory
# endpoint/key here (sourced in this shell) right before the final exec.
if [ -n "$MEMORY_ENV" ] && [ -r "$MEMORY_ENV" ]; then
  # shellcheck source=/dev/null
  AGENT_DEVBOX_MEMORY_UID="$PASEO_UID" \
    AGENT_DEVBOX_MEMORY_HOME="$PASEO_HOME_DIR" \
    . "$MEMORY_ENV"
fi

# Foreground daemon as paseo, with the deployment env overrides.
exec "$GOSU_BIN" "$PASEO_USER" "$ENV_BIN" \
  HOME="$PASEO_HOME_DIR" \
  PASEO_HOME="$PASEO_HOME" \
  PASEO_LISTEN="$PASEO_LISTEN" \
  PASEO_WEB_UI_ENABLED="$PASEO_WEB_UI_ENABLED" \
  PASEO_PASSWORD="$PASEO_PASSWORD" \
  paseo daemon run
