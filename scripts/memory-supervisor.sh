#!/usr/bin/env bash
# =============================================================================
# memory-supervisor.sh — one resident mcp-memory-service per UID, loopback only.
#
# `ensure <uid> <home>` (idempotent, flock-serialised):
#   * runtime dir  /run/agent-memory/<uid>                 (mode 0700)
#   * API key      <home>/.local/share/mcp-memory/api-key  (mode 0600, 256-bit)
#   * endpoint     <runtime>/endpoint  — written ONLY after an authenticated
#                  GET /api/health AND GET /api/health/detailed both return 200
#   * service      python3 /usr/local/bin/memory_guard.py on 127.0.0.1:<free port>
#                  (root → `gosu paseo` for uid 1000; paseo runs itself directly),
#                  cwd `/`, with MCP_ALLOW_ANONYMOUS_ACCESS=false and OAuth off.
#
# The guard (memory_guard.py) strips the dashboard/static/credential/OAuth routes
# and 404s anything outside its allowlist, so only /mcp, the plugin's REST calls
# and the two health routes are reachable.
#
# `stop <uid>` and `status <uid>` only ever signal the PID this script recorded
# (pid + kernel starttime), never a port owner.
#
# OPENCODE_MEMORY_AUTOSTART=false is the kill switch: `ensure` logs and returns
# without starting anything.
# =============================================================================
set -euo pipefail

RUNTIME_ROOT="${AGENT_DEVBOX_MEMORY_RUNTIME_ROOT:-/run/agent-memory}"
RUNTIME_DIR_OVERRIDE="${AGENT_DEVBOX_MEMORY_RUNTIME_DIR:-}"
GUARD="${AGENT_DEVBOX_MEMORY_GUARD:-/usr/local/bin/memory_guard.py}"
ASSET_DIR="${AGENT_DEVBOX_MEMORY_ASSET_DIR:-/opt/agent-memory}"
PYTHON_OVERRIDE="${AGENT_DEVBOX_PYTHON_BIN:-}"
PORT_OVERRIDE="${AGENT_DEVBOX_MEMORY_PORT:-}"
HEALTH_TIMEOUT="${AGENT_DEVBOX_MEMORY_HEALTH_TIMEOUT:-180}"
HEALTH_POLL="${AGENT_DEVBOX_MEMORY_HEALTH_POLL:-0.5}"
HEALTH_MAX_TIME="${AGENT_DEVBOX_MEMORY_HEALTH_MAX_TIME:-5}"
LOCK_WAIT="${AGENT_DEVBOX_MEMORY_LOCK_WAIT:-60}"
LOG_MAX="${AGENT_DEVBOX_MEMORY_LOG_MAX:-5242880}"

CURL_BIN="${AGENT_DEVBOX_CURL_BIN:-$(command -v curl 2>/dev/null || true)}"
GOSU_BIN="${AGENT_DEVBOX_GOSU_BIN-$(command -v gosu 2>/dev/null || true)}"
FLOCK_BIN="${AGENT_DEVBOX_FLOCK_BIN:-$(command -v flock 2>/dev/null || true)}"
STAT_BIN="${AGENT_DEVBOX_STAT_BIN:-$(command -v stat 2>/dev/null || true)}"
CHOWN_BIN="${AGENT_DEVBOX_CHOWN_BIN:-$(command -v chown 2>/dev/null || true)}"
CHMOD_BIN="${AGENT_DEVBOX_CHMOD_BIN:-$(command -v chmod 2>/dev/null || true)}"
ID_BIN="${AGENT_DEVBOX_ID_BIN:-$(command -v id 2>/dev/null || true)}"
SETSID_BIN="${AGENT_DEVBOX_SETSID_BIN:-$(command -v setsid 2>/dev/null || true)}"
ENV_BIN="${AGENT_DEVBOX_ENV_BIN:-$(command -v env 2>/dev/null || true)}"
# Set by start_service (global on purpose so ensure_service can record it).
SERVICE_PID=""

log() {
  printf '[memory-supervisor %s] %s\n' "$(date -Is)" "$*"
}

warn() {
  printf '[memory-supervisor %s] WARN: %s\n' "$(date -Is)" "$*" >&2
}

die() {
  printf '[memory-supervisor] FATAL: %s\n' "$*" >&2
  exit 1
}

autostart_disabled() {
  case "${OPENCODE_MEMORY_AUTOSTART:-true}" in
    false|FALSE|False|0|no|off) return 0 ;;
  esac
  return 1
}

runtime_dir() {
  if [ -n "$RUNTIME_DIR_OVERRIDE" ]; then
    printf '%s\n' "$RUNTIME_DIR_OVERRIDE"
  else
    printf '%s\n' "$RUNTIME_ROOT/$1"
  fi
}

resolve_python() {
  local candidate
  if [ -n "$PYTHON_OVERRIDE" ]; then
    printf '%s\n' "$PYTHON_OVERRIDE"
    return 0
  fi
  # `uv tool install` puts the package in an isolated venv; only that venv's
  # interpreter can import it. Prefer it over the system python3.
  for candidate in \
    /opt/uv-tools/mcp-memory-service/bin/python \
    /opt/uv-tools/mcp_memory_service/bin/python; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  # The uv console shim's shebang names the venv interpreter that owns the package.
  if [ -r /usr/local/bin/mcp-memory-service ]; then
    candidate="$(head -n 1 /usr/local/bin/mcp-memory-service 2>/dev/null || true)"
    case "$candidate" in
      '#!'*)
        candidate="${candidate#\#\!}"
        candidate="${candidate%% *}"
        if [ -x "$candidate" ]; then
          printf '%s\n' "$candidate"
          return 0
        fi
        ;;
    esac
  fi
  candidate="$(command -v python3 2>/dev/null || true)"
  [ -n "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

proc_starttime() {
  local pid="$1" stat rest
  [ -r "/proc/$pid/stat" ] || return 1
  stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  rest="${stat##*) }"
  printf '%s\n' "$rest" | awk '{print $20}'
}

proc_state() {
  local pid="$1" stat rest
  stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  rest="${stat##*) }"
  printf '%s\n' "${rest%% *}"
}

process_alive() {
  local pid="$1" state
  [ -e "/proc/$pid" ] || return 1
  state="$(proc_state "$pid" 2>/dev/null || true)"
  [ "$state" != "Z" ]
}

current_uid() {
  if [ -n "$ID_BIN" ]; then
    "$ID_BIN" -u
    return 0
  fi
  printf '%s\n' "${EUID:-0}"
}

gid_for() {
  local uid="$1" home="$2" gid
  if [ "$uid" = "0" ]; then
    printf '0\n'
    return 0
  fi
  if [ -n "$STAT_BIN" ] && [ -d "$home" ]; then
    gid="$("$STAT_BIN" -c '%g' -- "$home" 2>/dev/null || true)"
    if [ -n "$gid" ]; then
      printf '%s\n' "$gid"
      return 0
    fi
  fi
  if [ -n "$ID_BIN" ]; then
    gid="$("$ID_BIN" -g "$uid" 2>/dev/null || true)"
    if [ -n "$gid" ]; then
      printf '%s\n' "$gid"
      return 0
    fi
  fi
  return 1
}

ensure_owner() {
  local path="$1" uid="$2" gid="$3" cur
  [ -n "$STAT_BIN" ] || return 0
  [ -n "$CHOWN_BIN" ] || return 0
  cur="$("$STAT_BIN" -c '%u:%g' -- "$path" 2>/dev/null || true)"
  if [ "$cur" = "$uid:$gid" ]; then
    return 0
  fi
  if ! "$CHOWN_BIN" "$uid:$gid" -- "$path"; then
    warn "could not chown $path to $uid:$gid"
    return 1
  fi
  return 0
}

gen_key() {
  local key
  key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  case "$key" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#key}" -eq 64 ] || return 1
  printf '%s\n' "$key"
}

ensure_key() {
  local uid="$1" gid="$2" home="$3" dir file key
  dir="$home/.local/share/mcp-memory"
  file="$dir/api-key"
  mkdir -p -- "$dir"
  ensure_owner "$dir" "$uid" "$gid" || true
  key=""
  if [ -s "$file" ]; then
    key="$(head -n 1 -- "$file" 2>/dev/null || true)"
  fi
  if [ -z "$key" ]; then
    key="$(gen_key)" || {
      warn "could not generate an API key"
      return 1
    }
    ( umask 077; printf '%s\n' "$key" > "$file" )
  fi
  if [ -n "$CHMOD_BIN" ]; then
    "$CHMOD_BIN" 0600 -- "$file" 2>/dev/null || true
  fi
  ensure_owner "$file" "$uid" "$gid" || true
  printf '%s\n' "$key"
}

install_assets() {
  local uid="$1" gid="$2" home="$3" cfg pdir src dest pair
  cfg="$home/.config/opencode"
  pdir="$cfg/plugins"
  mkdir -p -- "$pdir"
  ensure_owner "$cfg" "$uid" "$gid" || true
  ensure_owner "$pdir" "$uid" "$gid" || true
  for pair in \
    "memory-plugin.js:$pdir/memory-plugin.js" \
    "memory-plugin.json:$cfg/memory-plugin.json"; do
    src="$ASSET_DIR/${pair%%:*}"
    dest="${pair#*:}"
    if [ -L "$dest" ] || [ -e "$dest" ]; then
      continue
    fi
    if [ ! -f "$src" ]; then
      warn "missing memory asset $src"
      continue
    fi
    cp -- "$src" "$dest"
    if [ -n "$CHMOD_BIN" ]; then
      "$CHMOD_BIN" 0644 -- "$dest" 2>/dev/null || true
    fi
    ensure_owner "$dest" "$uid" "$gid" || true
    log "installed $dest"
  done
}

read_pidfile() {
  local f="$1" pid start
  [ -r "$f" ] || return 1
  {
    IFS= read -r pid || true
    IFS= read -r start || true
  } < "$f"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$start" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s %s\n' "$pid" "$start"
}

write_pidfile() {
  local f="$1" pid="$2" start tmp
  start="$(proc_starttime "$pid")" || return 1
  tmp="$f.tmp.$$"
  printf '%s\n%s\n' "$pid" "$start" > "$tmp"
  mv -f -- "$tmp" "$f"
  return 0
}

rotate_log() {
  local f="$1" size
  [ -f "$f" ] || return 0
  if [ -n "$STAT_BIN" ]; then
    size="$("$STAT_BIN" -c %s -- "$f" 2>/dev/null || printf '0')"
  else
    size=0
  fi
  if [ "${size:-0}" -gt "$LOG_MAX" ]; then
    if ! mv -f -- "$f" "$f.1" 2>/dev/null; then
      : > "$f"
    fi
  fi
  return 0
}

pick_port() {
  local py port i
  if [ -n "$PORT_OVERRIDE" ]; then
    port="$PORT_OVERRIDE"
  else
    py="$(resolve_python)" || return 1
    port=""
    for i in 1 2 3 4 5; do
      port="$("$py" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || true)"
      if [ -n "$port" ]; then
        break
      fi
      sleep 0.1
    done
  fi
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    return 1
  fi
  printf '%s\n' "$port"
}

write_header_file() {
  local runtime="$1" key="$2" uid="$3" gid="$4" file
  file="$runtime/health.headers"
  ( umask 077; printf 'X-API-Key: %s\n' "$key" > "$file" )
  if [ -n "$CHMOD_BIN" ]; then
    "$CHMOD_BIN" 0600 -- "$file" 2>/dev/null || true
  fi
  ensure_owner "$file" "$uid" "$gid" || true
  return 0
}

http_code() {
  local url="$1" header_file="$2"
  [ -n "$CURL_BIN" ] || return 1
  "$CURL_BIN" -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
    --max-time "$HEALTH_MAX_TIME" -H "@$header_file" "$url" 2>/dev/null || true
}

health_ok() {
  local port="$1" header_file="$2" base code
  base="http://127.0.0.1:$port"
  # /api/health proves liveness; /api/health/detailed requires the API key, so a
  # 200 there proves the key the plugin will send is actually accepted.
  code="$(http_code "$base/api/health" "$header_file")"
  if [ "$code" != "200" ]; then
    return 1
  fi
  code="$(http_code "$base/api/health/detailed" "$header_file")"
  if [ "$code" != "200" ]; then
    return 1
  fi
  return 0
}

wait_healthy() {
  local pid="$1" port="$2" header_file="$3" deadline
  deadline=$((SECONDS + HEALTH_TIMEOUT))
  while :; do
    if health_ok "$port" "$header_file"; then
      return 0
    fi
    if [ -n "$pid" ] && ! process_alive "$pid"; then
      return 1
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      return 1
    fi
    sleep "$HEALTH_POLL"
  done
}

publish_endpoint() {
  local runtime="$1" port="$2" uid="$3" gid="$4" tmp
  tmp="$runtime/endpoint.tmp.$$"
  printf 'http://127.0.0.1:%s\n' "$port" > "$tmp"
  if [ -n "$CHMOD_BIN" ]; then
    "$CHMOD_BIN" 0600 -- "$tmp" 2>/dev/null || true
  fi
  ensure_owner "$tmp" "$uid" "$gid" || true
  mv -f -- "$tmp" "$runtime/endpoint"
}

clear_state() {
  local runtime="$1"
  rm -f -- "$runtime/endpoint" "$runtime/port" "$runtime/pid" "$runtime/health.headers"
}

stop_by_pidfile() {
  local runtime="$1" info pid start i
  if info="$(read_pidfile "$runtime/pid")"; then
    pid="${info%% *}"
    start="${info#* }"
    if process_alive "$pid" && [ "$(proc_starttime "$pid" 2>/dev/null || true)" = "$start" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      i=0
      while [ "$i" -lt 50 ]; do
        if ! process_alive "$pid"; then
          break
        fi
        sleep 0.1
        i=$((i + 1))
      done
      if process_alive "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
      log "stopped memory service pid=$pid"
    else
      warn "pid $pid is gone or was reused; not signalling it"
    fi
  fi
  clear_state "$runtime"
}

start_service() {
  local runtime="$1" uid="$2" gid="$3" home="$4" key="$5" port="$6"
  local py euid logfile launch_user cmd_string
  local -a gosu_cmd env_cmd
  py="$(resolve_python)" || {
    warn "no python interpreter (set AGENT_DEVBOX_PYTHON_BIN)"
    return 1
  }
  [ -f "$GUARD" ] || {
    warn "missing guard script $GUARD"
    return 1
  }
  [ -n "$SETSID_BIN" ] || {
    warn "setsid not found"
    return 1
  }
  [ -n "$ENV_BIN" ] || {
    warn "env not found"
    return 1
  }
  logfile="$runtime/service.log"
  rotate_log "$logfile"
  euid="$(current_uid)"

  env_cmd=(
    "HOME=$home"
    "MCP_API_KEY=$key"
    "MCP_ALLOW_ANONYMOUS_ACCESS=false"
    "MCP_OAUTH_ENABLED=false"
    "MCP_MEMORY_STORAGE_BACKEND=sqlite_vec"
    "MCP_MEMORY_BASE_DIR=$home/.local/share/mcp-memory"
    "MCP_MEMORY_SQLITE_PATH=$home/.local/share/mcp-memory/sqlite_vec.db"
    "MCP_MEMORY_USE_ONNX=true"
    "MCP_MEMORY_ALLOW_HASH_EMBEDDINGS=false"
    "MCP_HTTP_HOST=127.0.0.1"
    "MCP_HTTP_PORT=$port"
    "MCP_MDNS_ENABLED=false"
    "MCP_HTTPS_ENABLED=false"
    "PYTHONUNBUFFERED=1"
  )

  if [ "$uid" != "0" ] && [ "$euid" = "0" ]; then
    [ -n "$GOSU_BIN" ] || {
      warn "gosu not found; cannot drop root to uid $uid"
      return 1
    }
    case "$uid" in
      1000) launch_user="paseo" ;;
      *) launch_user="$uid:$gid" ;;
    esac
    gosu_cmd=("$GOSU_BIN" "$launch_user" "$ENV_BIN" "${env_cmd[@]}" \
      "$py" "$GUARD" --host 127.0.0.1 --port "$port")
    cmd_string="${gosu_cmd[*]}"
  elif [ "$uid" = "0" ] || [ "$euid" = "$uid" ]; then
    gosu_cmd=("$ENV_BIN" "${env_cmd[@]}" \
      "$py" "$GUARD" --host 127.0.0.1 --port "$port")
    cmd_string="${gosu_cmd[*]}"
  else
    warn "cannot switch from uid $euid to uid $uid"
    return 1
  fi

  log "starting memory service uid=$uid port=$port"
  # `setsid` execs the command in a new session, so $! is the service PID.
  ( cd / && exec "$SETSID_BIN" "${gosu_cmd[@]}" ) >>"$logfile" 2>&1 &
  SERVICE_PID=$!
  if ! write_pidfile "$runtime/pid" "$SERVICE_PID"; then
    warn "service exited immediately; see $logfile"
    kill -TERM "$SERVICE_PID" 2>/dev/null || true
    return 1
  fi
  # Keep the recorded argv-free command for status/debugging without secrets.
  printf '%s\n' "$cmd_string" | sed 's/MCP_API_KEY=[^ ]*/MCP_API_KEY=<redacted>/g' \
    > "$runtime/cmdline"
  return 0
}

ensure_service() {
  local uid="$1" home="$2" runtime gid key header_file pidfile info pid start port
  case "$uid" in
    ''|*[!0-9]*) die "uid must be numeric: $uid" ;;
  esac
  case "$home" in
    /*) ;;
    *) die "home must be an absolute path: $home" ;;
  esac
  [ -d "$home" ] || die "home does not exist: $home"

  if autostart_disabled; then
    log "autostart disabled by OPENCODE_MEMORY_AUTOSTART=${OPENCODE_MEMORY_AUTOSTART:-}"
    return 0
  fi

  runtime="$(runtime_dir "$uid")"
  mkdir -p -- "$runtime"
  if [ -n "$CHMOD_BIN" ]; then
    "$CHMOD_BIN" 0700 -- "$runtime" 2>/dev/null || true
  fi
  gid="$(gid_for "$uid" "$home")" || die "cannot resolve gid for uid $uid"
  ensure_owner "$runtime" "$uid" "$gid" || true

  [ -n "$FLOCK_BIN" ] || die "flock not found"
  exec 9>"$runtime/start.lock"
  if ! "$FLOCK_BIN" -w "$LOCK_WAIT" 9; then
    die "could not acquire the memory start lock within ${LOCK_WAIT}s"
  fi

  pidfile="$runtime/pid"
  key="$(ensure_key "$uid" "$gid" "$home")" || die "could not prepare the API key"
  header_file="$runtime/health.headers"
  write_header_file "$runtime" "$key" "$uid" "$gid"
  install_assets "$uid" "$gid" "$home"

  if info="$(read_pidfile "$pidfile")"; then
    pid="${info%% *}"
    start="${info#* }"
    if process_alive "$pid" && [ "$(proc_starttime "$pid" 2>/dev/null || true)" = "$start" ]; then
      port="$(cat "$runtime/port" 2>/dev/null || true)"
      case "$port" in
        ''|*[!0-9]*) port="" ;;
      esac
      if [ -n "$port" ]; then
        if wait_healthy "$pid" "$port" "$header_file"; then
          publish_endpoint "$runtime" "$port" "$uid" "$gid"
          log "reusing healthy memory service (uid=$uid pid=$pid port=$port)"
          return 0
        fi
        if process_alive "$pid"; then
          warn "existing memory service is not healthy yet; keeping it and returning"
          return 1
        fi
      fi
      warn "existing memory service is unhealthy; restarting (uid=$uid)"
      stop_by_pidfile "$runtime"
    else
      clear_state "$runtime"
    fi
  fi

  port="$(pick_port)" || die "could not pick a free loopback port"
  printf '%s\n' "$port" > "$runtime/port"
  if ! start_service "$runtime" "$uid" "$gid" "$home" "$key" "$port"; then
    clear_state "$runtime"
    return 1
  fi
  pid="$SERVICE_PID"
  if wait_healthy "$pid" "$port" "$header_file"; then
    publish_endpoint "$runtime" "$port" "$uid" "$gid"
    log "memory service ready (uid=$uid pid=$pid port=$port)"
    return 0
  fi
  warn "memory service did not become healthy within ${HEALTH_TIMEOUT}s; no endpoint published (log: $runtime/service.log)"
  if ! process_alive "$pid"; then
    clear_state "$runtime"
  fi
  return 1
}

stop_service() {
  local uid="$1" runtime
  runtime="$(runtime_dir "$uid")"
  stop_by_pidfile "$runtime"
  return 0
}

status_service() {
  local uid="$1" runtime info pid start port
  runtime="$(runtime_dir "$uid")"
  if ! info="$(read_pidfile "$runtime/pid")"; then
    printf 'memory service uid=%s: stopped (no pidfile)\n' "$uid"
    return 1
  fi
  pid="${info%% *}"
  start="${info#* }"
  port="$(cat "$runtime/port" 2>/dev/null || true)"
  if process_alive "$pid" && [ "$(proc_starttime "$pid" 2>/dev/null || true)" = "$start" ]; then
    printf 'memory service uid=%s: running pid=%s port=%s\n' "$uid" "$pid" "$port"
    if [ -r "$runtime/endpoint" ]; then
      printf 'endpoint: %s\n' "$(cat "$runtime/endpoint" 2>/dev/null || true)"
    else
      printf 'endpoint: not published\n'
    fi
    return 0
  fi
  printf 'memory service uid=%s: stale pidfile (pid=%s)\n' "$uid" "$pid"
  return 1
}

usage() {
  cat <<'EOF'
usage: memory-supervisor.sh <command> [args]

  ensure <uid> <home>   start (or reuse) the per-UID memory service
  stop <uid>            stop the service this script recorded for <uid>
  status <uid>          report PID/port/endpoint for <uid>
EOF
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

case "${1:-}" in
  ensure)
    [ "$#" -eq 3 ] || {
      usage
      exit 2
    }
    ensure_service "$2" "$3"
    ;;
  stop)
    [ "$#" -eq 2 ] || {
      usage
      exit 2
    }
    stop_service "$2"
    ;;
  status)
    [ "$#" -eq 2 ] || {
      usage
      exit 2
    }
    status_service "$2"
    ;;
  *)
    usage
    exit 2
    ;;
esac
