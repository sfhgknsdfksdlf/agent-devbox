#!/usr/bin/env bats
# T1b: the mcp-memory-service runtime — loopback guard allowlist, per-UID
# supervisor, env export and the boot/static contracts.
#
# Offline: no package import, no network, no real service. The guard's pure
# allowlist is imported directly; the supervisor runs against fake curl/gosu/
# flock/chown/id/setsid/python and a temp runtime + home, so every start is a
# harmless `sleep` that the teardown reaps.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GUARD="$REPO_ROOT/scripts/memory_guard.py"
  SUPERVISOR="$REPO_ROOT/scripts/memory-supervisor.sh"
  MEMENV="$REPO_ROOT/scripts/memory-env.sh"

  TMP="$BATS_TEST_TMPDIR"
  BIN="$TMP/bin"
  RUNTIME_ROOT="$TMP/run"
  HOME_DIR="$TMP/home"
  ASSET_DIR="$TMP/assets"
  GUARD_STUB="$TMP/memory_guard.py"
  mkdir -p "$BIN" "$RUNTIME_ROOT" "$HOME_DIR" "$ASSET_DIR"
  : > "$GUARD_STUB"
  printf 'PLUGIN-VENDORED\n' > "$ASSET_DIR/memory-plugin.js"
  printf '{"autoCapture":{"enabled":true},"memoryService":{"includeProjectTag":true}}\n' \
    > "$ASSET_DIR/memory-plugin.json"

  export FAKE_CURL_LOG="$TMP/curl.log"
  export FAKE_GOSU_LOG="$TMP/gosu.log"
  export FAKE_FLOCK_LOG="$TMP/flock.log"
  export FAKE_CHOWN_LOG="$TMP/chown.log"
  export FAKE_HEALTH_CODE=200
  export FAKE_ID_U=0
  export FAKE_ID_G=1000

  cat > "$BIN/curl" <<'SH'
#!/bin/sh
last=""
for arg in "$@"; do
  last="$arg"
done
printf '%s %s\n' "${FAKE_HEALTH_CODE:-200}" "$last" >> "${FAKE_CURL_LOG:?}"
printf '%s' "${FAKE_HEALTH_CODE:-200}"
SH
  cat > "$BIN/flock" <<'SH'
#!/bin/sh
printf 'flock %s\n' "$*" >> "${FAKE_FLOCK_LOG:?}"
exit 0
SH
  cat > "$BIN/chown" <<'SH'
#!/bin/sh
printf 'chown %s\n' "$*" >> "${FAKE_CHOWN_LOG:?}"
exit 0
SH
  cat > "$BIN/id" <<'SH'
#!/bin/sh
case "${1:-}" in
  -u) printf '%s\n' "${FAKE_ID_U:-0}" ;;
  -g) printf '%s\n' "${FAKE_ID_G:-1000}" ;;
  *) exit 1 ;;
esac
SH
  cat > "$BIN/setsid" <<'SH'
#!/bin/sh
exec "$@"
SH
  cat > "$BIN/python3" <<'SH'
#!/bin/sh
exec /bin/sleep 120
SH
  cat > "$BIN/gosu" <<'SH'
#!/bin/sh
printf 'user=%s\n' "${1:-}" >> "${FAKE_GOSU_LOG:?}"
shift
safe=""
for arg in "$@"; do
  case "$arg" in
    MCP_API_KEY=*) arg="MCP_API_KEY=<redacted>" ;;
  esac
  safe="$safe $arg"
done
printf 'args=%s\n' "$safe" >> "${FAKE_GOSU_LOG:?}"
exec "$@"
SH
  chmod +x "$BIN/curl" "$BIN/flock" "$BIN/chown" "$BIN/id" "$BIN/setsid" \
    "$BIN/python3" "$BIN/gosu"

  export AGENT_DEVBOX_MEMORY_RUNTIME_ROOT="$RUNTIME_ROOT"
  export AGENT_DEVBOX_MEMORY_ASSET_DIR="$ASSET_DIR"
  export AGENT_DEVBOX_MEMORY_GUARD="$GUARD_STUB"
  export AGENT_DEVBOX_MEMORY_PORT=45231
  export AGENT_DEVBOX_MEMORY_HEALTH_TIMEOUT=1
  export AGENT_DEVBOX_MEMORY_HEALTH_POLL=0.02
  export AGENT_DEVBOX_MEMORY_HEALTH_MAX_TIME=1
  export AGENT_DEVBOX_CURL_BIN="$BIN/curl"
  export AGENT_DEVBOX_GOSU_BIN="$BIN/gosu"
  export AGENT_DEVBOX_FLOCK_BIN="$BIN/flock"
  export AGENT_DEVBOX_CHOWN_BIN="$BIN/chown"
  export AGENT_DEVBOX_ID_BIN="$BIN/id"
  export AGENT_DEVBOX_SETSID_BIN="$BIN/setsid"
  export AGENT_DEVBOX_PYTHON_BIN="$BIN/python3"
  export AGENT_DEVBOX_ENV_BIN="$(command -v env)"
  unset AGENT_DEVBOX_MEMORY_RUNTIME_DIR AGENT_DEVBOX_MEMORY_UID \
    AGENT_DEVBOX_MEMORY_HOME OPENCODE_MEMORY_AUTOSTART 2>/dev/null || true
}

teardown() {
  local f pid
  for f in "$RUNTIME_ROOT"/*/pid; do
    [ -f "$f" ] || continue
    pid="$(head -n 1 "$f" 2>/dev/null || true)"
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill -KILL "$pid" 2>/dev/null || true
  done
}

guard_allows() {
  PYTHONPATH="$REPO_ROOT/scripts" python3 -c \
    'import sys; from memory_guard import is_allowed; print("yes" if is_allowed(sys.argv[1], sys.argv[2]) else "no")' \
    "$1" "$2"
}

# ---------------------------------------------------------------------------
# guard allowlist (pure; the package is NOT installed in this environment)
# ---------------------------------------------------------------------------
@test "guard: allows exactly the MCP, plugin REST and health surface" {
  local spec method path
  for spec in \
    "POST /mcp" "POST /mcp/" "GET /mcp" \
    "POST /api/memories" "DELETE /api/memories/abc123" \
    "POST /api/search" "POST /api/search/by-tag" "POST /api/harvest" \
    "GET /api/health" "GET /api/health/detailed"; do
    method="${spec%% *}"
    path="${spec#* }"
    if [ "$(guard_allows "$method" "$path")" != "yes" ]; then
      echo "expected allowed: $method $path"
      return 1
    fi
  done
}

@test "guard: denies dashboard, static, credential, configuration and unknown paths" {
  local spec method path
  for spec in \
    "GET /" "GET /static/js/app.js" "GET /static/index.html" \
    "POST /api/config/credentials" "GET /api/config/credentials" \
    "GET /api/config/env" "GET /api/configuration/anything" \
    "POST /api/oauth/token" "GET /api/docs" "GET /openapi.json" \
    "GET /api/memories" "POST /api/memories/resonance-search" \
    "GET /api/health/model" "GET /api/memory-stats" \
    "POST /mcp/tools" "GET /mcp/tools" "GET /unknown" "GET //api/health" \
    "GET /api/health/../config/env"; do
    method="${spec%% *}"
    path="${spec#* }"
    if [ "$(guard_allows "$method" "$path")" != "no" ]; then
      echo "expected denied: $method $path"
      return 1
    fi
  done
}

@test "guard: allowlist middleware is the only boundary (no route stripping)" {
  # FastAPI 0.165 represents include_router() as _IncludedRouter objects with
  # no path/methods; shape-based stripping would delete every API route.
  ! grep -Fq 'strip_routes' "$GUARD"
  grep -Fq 'install_middleware(upstream_app)' "$GUARD"
  grep -Fq 'build_app(upstream_app=None)' "$GUARD"
  grep -Fq 'memory_guard_selftest.py' "$REPO_ROOT/Dockerfile"
}

@test "guard: binds only 127.0.0.1 and forces anonymous/OAuth off" {
  grep -Fq 'host="127.0.0.1",' "$GUARD"
  grep -Fq 'ws="none"' "$GUARD"
  ! grep -Fq 'host="0.0.0.0"' "$GUARD"
  grep -Fq 'MCP_ALLOW_ANONYMOUS_ACCESS' "$GUARD"
  grep -Fq 'MCP_OAUTH_ENABLED' "$GUARD"
  grep -Fq 'MCP_MDNS_ENABLED' "$GUARD"
}

# ---------------------------------------------------------------------------
# supervisor
# ---------------------------------------------------------------------------
@test "supervisor: ensure drops to paseo, 0600 key, assets, health-gated endpoint" {
  run bash "$SUPERVISOR" ensure 1000 "$HOME_DIR"
  [ "$status" -eq 0 ]
  run grep -F 'user=paseo' "$FAKE_GOSU_LOG"
  [ "$status" -eq 0 ]
  run grep -F 'memory_guard.py' "$FAKE_GOSU_LOG"
  [ "$status" -eq 0 ]
  run grep -F 'MCP_ALLOW_ANONYMOUS_ACCESS=false' "$FAKE_GOSU_LOG"
  [ "$status" -eq 0 ]
  run grep -F 'MCP_OAUTH_ENABLED=false' "$FAKE_GOSU_LOG"
  [ "$status" -eq 0 ]
  run grep -F 'MCP_MEMORY_STORAGE_BACKEND=sqlite_vec' "$FAKE_GOSU_LOG"
  [ "$status" -eq 0 ]
  run grep -F 'MCP_MEMORY_USE_ONNX=true' "$FAKE_GOSU_LOG"
  [ "$status" -eq 0 ]
  ! grep -F 'MCP_API_KEY=' "$FAKE_GOSU_LOG"

  local key="$HOME_DIR/.local/share/mcp-memory/api-key"
  [ -f "$key" ]
  [ "$(stat -c %a "$key")" = "600" ]
  [[ "$(cat "$key")" =~ ^[0-9a-f]{64}$ ]]

  [ -f "$HOME_DIR/.config/opencode/plugins/memory-plugin.js" ]
  [ -f "$HOME_DIR/.config/opencode/memory-plugin.json" ]
  [ "$(cat "$HOME_DIR/.config/opencode/plugins/memory-plugin.js")" = "PLUGIN-VENDORED" ]

  [ "$(cat "$RUNTIME_ROOT/1000/endpoint")" = "http://127.0.0.1:45231" ]
  grep -F '/api/health' "$FAKE_CURL_LOG"
  grep -F '/api/health/detailed' "$FAKE_CURL_LOG"
  grep -F 'flock' "$FAKE_FLOCK_LOG"
}

@test "supervisor: a healthy service is reused without a second start" {
  run bash "$SUPERVISOR" ensure 1000 "$HOME_DIR"
  [ "$status" -eq 0 ]
  run bash "$SUPERVISOR" ensure 1000 "$HOME_DIR"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^user=paseo$' "$FAKE_GOSU_LOG")" -eq 1 ]
  [ "$(cat "$RUNTIME_ROOT/1000/endpoint")" = "http://127.0.0.1:45231" ]
}

@test "supervisor: no endpoint when health never returns 200" {
  export FAKE_HEALTH_CODE=503
  export AGENT_DEVBOX_MEMORY_HEALTH_TIMEOUT=0
  run bash "$SUPERVISOR" ensure 1000 "$HOME_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "$RUNTIME_ROOT/1000/endpoint" ]
  [ -f "$RUNTIME_ROOT/1000/service.log" ]
}

@test "supervisor: assets are missing-only and idempotent" {
  mkdir -p "$HOME_DIR/.config/opencode/plugins"
  printf 'USER-CUSTOM\n' > "$HOME_DIR/.config/opencode/plugins/memory-plugin.js"
  run bash "$SUPERVISOR" ensure 1000 "$HOME_DIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME_DIR/.config/opencode/plugins/memory-plugin.js")" = "USER-CUSTOM" ]
  printf 'USER-JSON\n' > "$HOME_DIR/.config/opencode/memory-plugin.json"
  run bash "$SUPERVISOR" ensure 1000 "$HOME_DIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME_DIR/.config/opencode/plugins/memory-plugin.js")" = "USER-CUSTOM" ]
  [ "$(cat "$HOME_DIR/.config/opencode/memory-plugin.json")" = "USER-JSON" ]
}

@test "supervisor: uid 0 runs directly and never calls gosu" {
  export FAKE_ID_U=0
  run bash "$SUPERVISOR" ensure 0 "$HOME_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_GOSU_LOG" ]
  [ "$(cat "$RUNTIME_ROOT/0/endpoint")" = "http://127.0.0.1:45231" ]
}

@test "supervisor: paseo running as its own uid never calls gosu" {
  export FAKE_ID_U=1000
  run bash "$SUPERVISOR" ensure 1000 "$HOME_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_GOSU_LOG" ]
  [ "$(cat "$RUNTIME_ROOT/1000/endpoint")" = "http://127.0.0.1:45231" ]
}

@test "supervisor: stop signals only its recorded PID and clears state" {
  run bash "$SUPERVISOR" ensure 1000 "$HOME_DIR"
  [ "$status" -eq 0 ]
  local pid
  pid="$(head -n 1 "$RUNTIME_ROOT/1000/pid")"
  run bash "$SUPERVISOR" stop 1000
  [ "$status" -eq 0 ]
  ! kill -0 "$pid" 2>/dev/null
  [ ! -e "$RUNTIME_ROOT/1000/pid" ]
  [ ! -e "$RUNTIME_ROOT/1000/endpoint" ]
  [ ! -e "$RUNTIME_ROOT/1000/port" ]
}

@test "supervisor: OPENCODE_MEMORY_AUTOSTART=false starts nothing" {
  export OPENCODE_MEMORY_AUTOSTART=false
  run bash "$SUPERVISOR" ensure 1000 "$HOME_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "$RUNTIME_ROOT/1000/pid" ]
  [ ! -e "$FAKE_GOSU_LOG" ]
}

@test "supervisor: never kills by port (PIDs only)" {
  ! grep -Eq 'fuser|lsof|netstat|ss -' "$SUPERVISOR"
  grep -Fq 'proc_starttime' "$SUPERVISOR"
  grep -Fq 'kill -TERM "$pid"' "$SUPERVISOR"
  # The health key goes through curl's -H @file, never into curl's argv.
  grep -Fq -- '-H "@$header_file"' "$SUPERVISOR"
  ! grep -Fq -- '-H "X-API-Key: $key"' "$SUPERVISOR"
}

# ---------------------------------------------------------------------------
# memory-env.sh
# ---------------------------------------------------------------------------
@test "memory-env: exports the published endpoint and key" {
  export AGENT_DEVBOX_MEMORY_UID=1000
  export AGENT_DEVBOX_MEMORY_HOME="$HOME_DIR"
  mkdir -p "$RUNTIME_ROOT/1000" "$HOME_DIR/.local/share/mcp-memory"
  printf 'http://127.0.0.1:9999\n' > "$RUNTIME_ROOT/1000/endpoint"
  printf 'deadbeef\n' > "$HOME_DIR/.local/share/mcp-memory/api-key"
  run bash -c '. "$1"; printf "E=%s\nK=%s\n" "${OPENCODE_MEMORY_ENDPOINT:-}" "${OPENCODE_MEMORY_API_KEY:-}"' \
    _ "$MEMENV"
  [ "$status" -eq 0 ]
  [ "$output" = "E=http://127.0.0.1:9999
K=deadbeef" ]
}

@test "memory-env: warns and exports nothing when the service is absent" {
  export AGENT_DEVBOX_MEMORY_UID=1000
  export AGENT_DEVBOX_MEMORY_HOME="$HOME_DIR"
  run bash -c '. "$1"; printf "E=%s K=%s\n" "${OPENCODE_MEMORY_ENDPOINT:-}" "${OPENCODE_MEMORY_API_KEY:-}"' \
    _ "$MEMENV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent memory is not running"* ]]
  [[ "$output" == *"E= K="* ]]
}

# ---------------------------------------------------------------------------
# static contracts
# ---------------------------------------------------------------------------
@test "static: vendored plugin matches SHA256SUMS and Dockerfile verifies it" {
  run bash -c 'cd "$1" && sha256sum -c SHA256SUMS' _ "$REPO_ROOT/config/agent-memory"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$REPO_ROOT/config/agent-memory/memory-plugin.js" | cut -d' ' -f1)" \
    = "db432757c41195b84b466f01334f93fa2288f5c38da5145b00bc636ac6f3410d" ]
  grep -Fq 'sha256sum -c SHA256SUMS' "$REPO_ROOT/Dockerfile"
}

@test "static: the managed config keeps memory remote/env and has NO plugin array" {
  run jq -e '.mcp.memory == {
    "type": "remote",
    "url": "{env:OPENCODE_MEMORY_ENDPOINT}/mcp",
    "headers": {"X-API-Key": "{env:OPENCODE_MEMORY_API_KEY}"},
    "oauth": false,
    "enabled": true
  }' "$REPO_ROOT/config/opencode/global-mcp.json"
  [ "$status" -eq 0 ]
  run jq -e 'has("plugin") | not' "$REPO_ROOT/config/opencode/global-mcp.json"
  [ "$status" -eq 0 ]
  grep -Fq 'jq -e '"'"'has("plugin") | not'"'"' /etc/opencode/opencode.json' \
    "$REPO_ROOT/Dockerfile"
}

@test "static: the plugin installs into the auto-discovered plugins dir" {
  grep -Fq 'pdir="$cfg/plugins"' "$SUPERVISOR"
  grep -Fq 'memory-plugin.js:$pdir/memory-plugin.js' "$SUPERVISOR"
  grep -Fq 'memory-plugin.json:$cfg/memory-plugin.json' "$SUPERVISOR"
  ! grep -Fq 'plugin"' "$REPO_ROOT/config/opencode/global-mcp.json"
}

@test "static: boot scripts use the supervisor, never a --http dashboard" {
  grep -Fq 'memory-supervisor.sh' "$REPO_ROOT/scripts/docker-entrypoint.sh"
  grep -Fq 'ensure 0 /root' "$REPO_ROOT/scripts/docker-entrypoint.sh"
  grep -Fq 'memory-supervisor.sh' "$REPO_ROOT/scripts/paseo-boot.sh"
  grep -Fq 'memory-env.sh' "$REPO_ROOT/scripts/paseo-boot.sh"
  grep -Fq 'memory-supervisor.sh' "$REPO_ROOT/scripts/wsl-boot.sh"
  ! grep -Eq -- '--http|MCP_HTTP_ENABLED=true|mcp-memory-service (run|serve|dashboard)' \
    "$REPO_ROOT/scripts/docker-entrypoint.sh" "$REPO_ROOT/scripts/paseo-boot.sh"
}

@test "static: profile.d exports memory env for login shells" {
  grep -Fq 'memory-env.sh' "$REPO_ROOT/config/profile.d/zz-agent-memory.sh"
}
