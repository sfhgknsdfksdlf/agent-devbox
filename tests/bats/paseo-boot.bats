#!/usr/bin/env bats
# paseo-boot.sh: a pidfile on the persistent data disk must not block the daemon
# after a WSL/container restart (the recorded PID is dead, or reused).

setup() {
  repo="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  # shellcheck disable=SC1091
  source "$repo/scripts/paseo-boot.sh"
  PASEO_HOME="$(mktemp -d)"
  export PASEO_HOME
}

teardown() {
  rm -rf "$PASEO_HOME"
}

@test "paseo-boot: a pidfile pointing at a dead pid is removed" {
  printf '{"pid":999999}' > "$PASEO_HOME/paseo.pid"
  run clear_stale_pidfile
  [ "$status" -eq 0 ]
  [ ! -f "$PASEO_HOME/paseo.pid" ]
}

@test "paseo-boot: a pid reused by a non-paseo process is removed" {
  sleep 30 &
  local pid=$!
  printf '{"pid":%s}' "$pid" > "$PASEO_HOME/paseo.pid"
  run clear_stale_pidfile
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ ! -f "$PASEO_HOME/paseo.pid" ]
}

@test "paseo-boot: a live paseo process keeps its pidfile" {
  bash -c 'exec -a paseo-daemon sleep 30' &
  local pid=$!
  sleep 1
  printf '{"pid":%s}' "$pid" > "$PASEO_HOME/paseo.pid"
  run clear_stale_pidfile
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ -f "$PASEO_HOME/paseo.pid" ]
}

@test "paseo-boot: the daemon start clears the pidfile before exec" {
  local clear_line exec_line
  clear_line="$(grep -n '^clear_stale_pidfile$' "$repo/scripts/paseo-boot.sh" | tail -n 1 | cut -d: -f1)"
  exec_line="$(grep -n 'exec "\$GOSU_BIN"' "$repo/scripts/paseo-boot.sh" | head -n 1 | cut -d: -f1)"
  [ -n "$clear_line" ]
  [ -n "$exec_line" ]
  [ "$clear_line" -lt "$exec_line" ]
}
