#!/usr/bin/env bats
# paseo-boot.sh: the Supervisor's own JSON pidfile on the persistent data disk
# must not block the daemon after a WSL/container restart. Only a lock proven
# dead, cross-boot, or held by a reused PID is dropped; a live Supervisor lock
# (real comm/title/exe identity) is kept.

setup() {
  repo="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  # shellcheck disable=SC1091
  source "$repo/scripts/paseo-boot.sh"
  PASEO_HOME="$(mktemp -d)"
  export PASEO_HOME
  NODE_STUB="$PASEO_HOME/Paseo Superviso"
  cp "$(command -v python3)" "$NODE_STUB"
  chmod +x "$NODE_STUB"
  export AGENT_DEVBOX_NODE_BIN="$NODE_STUB"
  export AGENT_DEVBOX_PASEO_UID="$(id -u)"
  export AGENT_DEVBOX_BOOT_ID="boot-test"
  E2E_UID="$(id -u)"
}

teardown() {
  rm -rf "$PASEO_HOME"
}

write_lock() {
  printf '{"pid":%s,"startedAt":"2026-01-01T00:00:00.000Z","hostname":"h","uid":%s,"listen":null,"bootId":"%s"}' \
    "$1" "$E2E_UID" "$2" > "$PASEO_HOME/paseo.pid"
}

start_supervisor() {
  bash -c 'exec -a "Paseo Supervisor" "$1" -c "import time; time.sleep(30)"' _ "$NODE_STUB" &
  SUP_PID=$!
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(cat "/proc/$SUP_PID/comm" 2>/dev/null)" = "Paseo Superviso" ] && break
    /bin/sleep 0.05
  done
}

@test "paseo-boot: a pidfile pointing at a dead pid is removed" {
  write_lock 999999 boot-test
  run clear_stale_pidfile
  [ "$status" -eq 0 ]
  [ ! -f "$PASEO_HOME/paseo.pid" ]
}

@test "paseo-boot: a pid reused by a non-paseo process is removed" {
  sleep 30 &
  local pid=$!
  write_lock "$pid" boot-test
  run clear_stale_pidfile
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ ! -f "$PASEO_HOME/paseo.pid" ]
}

@test "paseo-boot: a real live Supervisor (comm/title/exe) keeps its pidfile" {
  start_supervisor
  write_lock "$SUP_PID" boot-test
  run clear_stale_pidfile
  kill "$SUP_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ -f "$PASEO_HOME/paseo.pid" ]
}

@test "paseo-boot: a briefly empty pidfile is never deleted" {
  : > "$PASEO_HOME/paseo.pid"
  run clear_stale_pidfile
  [ "$status" -eq 0 ]
  [ -f "$PASEO_HOME/paseo.pid" ]
}

@test "paseo-boot: a lock from another boot is dropped even while its PID lives" {
  start_supervisor
  write_lock "$SUP_PID" "old-boot"
  run clear_stale_pidfile
  kill -0 "$SUP_PID"
  alive=$?
  kill "$SUP_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$alive" -eq 0 ]
  [ ! -f "$PASEO_HOME/paseo.pid" ]
}

@test "paseo-boot: an old lock without bootId whose PID was reused is dropped" {
  sleep 30 &
  local pid=$!
  printf '{"pid":%s,"startedAt":"2026-01-01T00:00:00.000Z","hostname":"h","uid":%s,"listen":null}' \
    "$pid" "$E2E_UID" > "$PASEO_HOME/paseo.pid"
  run clear_stale_pidfile
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ ! -f "$PASEO_HOME/paseo.pid" ]
}

@test "paseo-boot: the daemon start clears the pidfile before exec" {
  local clear_line exec_line
  clear_line="$(grep -n '^clear_stale_pidfile$' "$repo/scripts/paseo-boot.sh" | tail -n 1 | cut -d: -f1)"
  exec_line="$(grep -n 'exec "\$GOSU_BIN"' "$repo/scripts/paseo-boot.sh" | head -n 1 | cut -d: -f1)"
  [ -n "$clear_line" ]
  [ -n "$exec_line" ]
  [ "$clear_line" -lt "$exec_line" ]
}

# ---------------------------------------------------------------------------
# Subprocess tests: the launcher must refuse empty / retired-default passwords
# BEFORE it calls gosu, the config seeder, or the daemon. Fake tools record
# only argv names / markers so the chosen test password never reaches a log.
# ---------------------------------------------------------------------------
make_fake_launcher_env() {
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  FAKE_LOG="$BATS_TEST_TMPDIR/fake-log"
  FAKE_HOME="$BATS_TEST_TMPDIR/fake-home"
  rm -rf "$FAKE_BIN" "$FAKE_LOG" "$FAKE_HOME"
  mkdir -p "$FAKE_BIN" "$FAKE_LOG" "$FAKE_HOME/.paseo"

  cat > "$FAKE_BIN/gosu" <<'SH'
#!/usr/bin/env bash
set -u
printf 'gosu user=%s argc=%s\n' "$1" "$#" >> "$FAKE_LOG/gosu.log"
shift
args=()
for arg in "$@"; do
  if [ "$arg" = "paseo" ]; then
    args+=("$FAKE_PASEO")
  else
    args+=("$arg")
  fi
done
exec "${args[@]}"
SH

  cat > "$FAKE_BIN/paseo" <<'SH'
#!/usr/bin/env bash
set -u
printf 'paseo argv=%s\n' "$*" >> "$FAKE_LOG/paseo.log"
printf '%s\n' "$*" > "$FAKE_LOG/paseo-argv"
if [ "$*" = "daemon run" ]; then
  if [ "${PASEO_PASSWORD:-}" = "${EXPECTED_PASEO_PASSWORD:-}" ]; then
    : > "$FAKE_LOG/daemon-env-ok"
  fi
  if [ "${PASEO_HOME:-}" = "${EXPECTED_PASEO_HOME:-}" ]; then
    : > "$FAKE_LOG/daemon-home-ok"
  fi
fi
exit 0
SH

  cat > "$FAKE_BIN/seed-agent-config.sh" <<'SH'
#!/usr/bin/env bash
set -u
: > "$FAKE_LOG/seed.log"
SH

  chmod +x "$FAKE_BIN/gosu" "$FAKE_BIN/paseo" "$FAKE_BIN/seed-agent-config.sh"
}

launcher_env() {
  make_fake_launcher_env
  LAUNCHER_ENV=(
    "PATH=$FAKE_BIN:/usr/bin:/bin"
    "HOME=$BATS_TEST_TMPDIR"
    "TMPDIR=$BATS_TEST_TMPDIR"
    "AGENT_DEVBOX_GOSU_BIN=$FAKE_BIN/gosu"
    "AGENT_DEVBOX_SEED_BIN=$FAKE_BIN/seed-agent-config.sh"
    "AGENT_DEVBOX_PASEO_HOME=$FAKE_HOME/.paseo"
    "AGENT_DEVBOX_PASEO_LOCK_DIR=$BATS_TEST_TMPDIR"
    "EXPECTED_PASEO_HOME=$FAKE_HOME/.paseo"
    "FAKE_LOG=$FAKE_LOG"
    "FAKE_PASEO=$FAKE_BIN/paseo"
  )
}

@test "paseo-boot: a missing PASEO_PASSWORD refuses before gosu/paseo/seed" {
  launcher_env
  run env -i "${LAUNCHER_ENV[@]}" bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PASEO_PASSWORD is not set"* ]]
  [ ! -e "$FAKE_LOG/gosu.log" ]
  [ ! -e "$FAKE_LOG/paseo.log" ]
  [ ! -e "$FAKE_LOG/seed.log" ]
  [ ! -e "$BATS_TEST_TMPDIR/agent-devbox-paseo.lock" ]
}

@test "paseo-boot: an empty PASEO_PASSWORD refuses before gosu/paseo/seed" {
  launcher_env
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD= bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PASEO_PASSWORD is not set"* ]]
  [ ! -e "$FAKE_LOG/gosu.log" ]
  [ ! -e "$FAKE_LOG/paseo.log" ]
  [ ! -e "$FAKE_LOG/seed.log" ]
  [ ! -e "$BATS_TEST_TMPDIR/agent-devbox-paseo.lock" ]
}

@test "paseo-boot: the retired public default refuses without echoing it" {
  launcher_env
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=change-me-please \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"public default"* ]]
  [[ "$output" != *"change-me-please"* ]]
  [ ! -e "$FAKE_LOG/gosu.log" ]
  [ ! -e "$FAKE_LOG/paseo.log" ]
  [ ! -e "$FAKE_LOG/seed.log" ]
  [ ! -e "$BATS_TEST_TMPDIR/agent-devbox-paseo.lock" ]
}

@test "paseo-boot: a user-chosen password reaches the daemon with the temp home" {
  launcher_env
  local chosen="user-chosen-test-password"
  run env -i "${LAUNCHER_ENV[@]}" \
    PASEO_PASSWORD="$chosen" \
    EXPECTED_PASEO_PASSWORD="$chosen" \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_LOG/gosu.log" ]
  [ -f "$FAKE_LOG/seed.log" ]
  [ -f "$FAKE_LOG/paseo.log" ]
  [ -f "$FAKE_LOG/daemon-env-ok" ]
  [ -f "$FAKE_LOG/daemon-home-ok" ]
  grep -q '^paseo argv=daemon run$' "$FAKE_LOG/paseo.log"
  [ "$(cat "$FAKE_LOG/paseo-argv")" = "daemon run" ]
  [[ "$output" != *"$chosen"* ]]
  if grep -q "$chosen" "$FAKE_LOG/gosu.log" "$FAKE_LOG/paseo.log"; then
    echo "the launcher must not log the password"
    return 1
  fi
}
