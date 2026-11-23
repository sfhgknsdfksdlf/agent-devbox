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
  FAKE_WORKSPACE="$BATS_TEST_TMPDIR/fake-workspace"
  FAKE_GIT_CONFIG="$BATS_TEST_TMPDIR/gitconfig"
  rm -rf "$FAKE_BIN" "$FAKE_LOG" "$FAKE_HOME" "$FAKE_WORKSPACE" "$FAKE_GIT_CONFIG"
  mkdir -p "$FAKE_BIN" "$FAKE_LOG" "$FAKE_HOME/.paseo" "$FAKE_WORKSPACE"

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
  printf '%s\n' "${PASEO_LISTEN:-}" > "$FAKE_LOG/daemon-listen"
  printf '%s\n' "${PASEO_WEB_UI_ENABLED:-}" > "$FAKE_LOG/daemon-webui"
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

  cat > "$FAKE_BIN/git" <<'SH'
#!/usr/bin/env bash
set -u
printf 'git HOME=%s argv=%s\n' "${HOME:-}" "$*" >> "$FAKE_LOG/git.log"
if [ "${1:-}" = "config" ] && [ "${2:-}" = "--global" ]; then
  case "${3:-}" in
    --get-all)
      [ "${4:-}" = "safe.directory" ] || exit 1
      [ -f "$FAKE_GIT_CONFIG" ] || exit 1
      cat "$FAKE_GIT_CONFIG"
      exit 0
      ;;
    --add)
      [ "${4:-}" = "safe.directory" ] || exit 1
      [ -z "${FAKE_GIT_ADD_FAIL:-}" ] || exit 1
      printf '%s\n' "${5:-}" >> "$FAKE_GIT_CONFIG"
      exit 0
      ;;
    *) exit 0 ;;
  esac
fi
exit 0
SH

  chmod +x "$FAKE_BIN/gosu" "$FAKE_BIN/paseo" "$FAKE_BIN/seed-agent-config.sh" "$FAKE_BIN/git"
}

launcher_env() {
  make_fake_launcher_env
  LAUNCHER_ENV=(
    "PATH=$FAKE_BIN:/usr/bin:/bin"
    "HOME=$BATS_TEST_TMPDIR"
    "TMPDIR=$BATS_TEST_TMPDIR"
    "AGENT_DEVBOX_GOSU_BIN=$FAKE_BIN/gosu"
    "AGENT_DEVBOX_GIT_BIN=$FAKE_BIN/git"
    "AGENT_DEVBOX_SEED_BIN=$FAKE_BIN/seed-agent-config.sh"
    "AGENT_DEVBOX_PASEO_HOME=$FAKE_HOME/.paseo"
    "AGENT_DEVBOX_PASEO_HOME_DIR=$FAKE_HOME"
    "AGENT_DEVBOX_WORKSPACE_DIR=$FAKE_WORKSPACE"
    "AGENT_DEVBOX_PASEO_UID=$(id -u)"
    "AGENT_DEVBOX_PASEO_GID=$(id -g)"
    "AGENT_DEVBOX_PASEO_LOCK_DIR=$BATS_TEST_TMPDIR"
    "EXPECTED_PASEO_HOME=$FAKE_HOME/.paseo"
    "FAKE_LOG=$FAKE_LOG"
    "FAKE_GIT_CONFIG=$FAKE_GIT_CONFIG"
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

# ---------------------------------------------------------------------------
# P1-3: PASEO_LISTEN / PASEO_WEB_UI_ENABLED are parsed ONCE, and the canonical
# values drive `daemon config set` and the final `daemon run` environment.
# ---------------------------------------------------------------------------

@test "paseo-boot: default listen/web-ui values reach config set and the daemon" {
  launcher_env
  local chosen="default-env-password"
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD="$chosen" \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  grep -Fxq 'paseo argv=daemon config set daemon.listen 0.0.0.0:6767' "$FAKE_LOG/paseo.log"
  grep -Fxq 'paseo argv=daemon config set features.webUi.enabled true' "$FAKE_LOG/paseo.log"
  [ "$(cat "$FAKE_LOG/daemon-listen")" = "0.0.0.0:6767" ]
  [ "$(cat "$FAKE_LOG/daemon-webui")" = "true" ]
  [[ "$output" != *"$chosen"* ]]
}

@test "paseo-boot: a custom listen/web-ui pair reaches config set and the daemon" {
  launcher_env
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=custom-env-password \
    PASEO_LISTEN=127.0.0.1:7777 PASEO_WEB_UI_ENABLED=false \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  grep -Fxq 'paseo argv=daemon config set daemon.listen 127.0.0.1:7777' "$FAKE_LOG/paseo.log"
  grep -Fxq 'paseo argv=daemon config set features.webUi.enabled false' "$FAKE_LOG/paseo.log"
  [ "$(cat "$FAKE_LOG/daemon-listen")" = "127.0.0.1:7777" ]
  [ "$(cat "$FAKE_LOG/daemon-webui")" = "false" ]
}

@test "paseo-boot: a bracketed IPv6 listen reaches config set and the daemon" {
  launcher_env
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=ipv6-env-password \
    'PASEO_LISTEN=[::1]:7777' \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  grep -Fxq 'paseo argv=daemon config set daemon.listen [::1]:7777' "$FAKE_LOG/paseo.log"
  [ "$(cat "$FAKE_LOG/daemon-listen")" = "[::1]:7777" ]
}

@test "paseo-boot: invalid listen/web-ui values fail before gosu/seed/daemon/lock" {
  local bad chosen="invalid-env-password"
  for bad in 'PASEO_LISTEN=127.0.0.1' 'PASEO_LISTEN=0.0.0.0:70000' \
    'PASEO_LISTEN=::1:6767' 'PASEO_WEB_UI_ENABLED=maybe'; do
    launcher_env
    run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD="$chosen" "$bad" \
      bash "$repo/scripts/paseo-boot.sh"
    [ "$status" -ne 0 ]
    [ ! -e "$FAKE_LOG/gosu.log" ]
    [ ! -e "$FAKE_LOG/paseo.log" ]
    [ ! -e "$FAKE_LOG/seed.log" ]
    [ ! -e "$BATS_TEST_TMPDIR/agent-devbox-paseo.lock" ]
    [[ "$output" != *"$chosen"* ]]
  done
}

# ---------------------------------------------------------------------------
# P2-B3: a held lock exits 0, any other flock failure is FATAL, and the
# top-level home/workspace ownership is verified by numeric uid:gid. Home
# failures stop before seed/daemon; workspace failures only warn.
# ---------------------------------------------------------------------------

make_fake_owner_tools() {
  cat > "$FAKE_BIN/stat" <<'SH'
#!/usr/bin/env bash
set -u
path="${!#}"
if [ -n "${FAKE_STAT_MARKER:-}" ] && [ -e "$FAKE_STAT_MARKER" ]; then
  printf '%s\n' "$FAKE_WANT"
elif [ "${FAKE_STAT_WRONG_ALL:-}" = 1 ]; then
  printf '%s\n' "$FAKE_WRONG_OWNER"
elif [ "$path" = "${FAKE_WRONG_PATH:-}" ]; then
  printf '%s\n' "$FAKE_WRONG_OWNER"
else
  printf '%s\n' "$FAKE_WANT"
fi
SH
  cat > "$FAKE_BIN/chown" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" >> "$FAKE_LOG/chown.log"
path="${!#}"
if [ -n "${FAKE_STAT_MARKER:-}" ]; then
  : > "$FAKE_STAT_MARKER"
fi
if [ "$path" = "${FAKE_CHOWN_FAIL_PATH:-}" ]; then
  exit 1
fi
exit 0
SH
  cat > "$FAKE_BIN/chown-fail" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" >> "$FAKE_LOG/chown.log"
: > "$FAKE_LOG/chown-called"
exit 1
SH
  chmod +x "$FAKE_BIN/stat" "$FAKE_BIN/chown" "$FAKE_BIN/chown-fail"
}

@test "paseo-boot: a held launcher lock exits 0 without gosu/seed/daemon" {
  launcher_env
  local lock="$BATS_TEST_TMPDIR/agent-devbox-paseo.lock" holder i
  ( flock -n 9 || exit 1; : > "$BATS_TEST_TMPDIR/lock-held"; /bin/sleep 30 ) 9>"$lock" &
  holder=$!
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$BATS_TEST_TMPDIR/lock-held" ] && break
    /bin/sleep 0.05
  done
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=lock-conflict-password \
    bash "$repo/scripts/paseo-boot.sh"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ -e "$BATS_TEST_TMPDIR/lock-held" ]
  [ "$status" -eq 0 ]
  [[ "$output" == *"paseo launcher is already running; nothing to do."* ]]
  [ ! -e "$FAKE_LOG/gosu.log" ]
  [ ! -e "$FAKE_LOG/paseo.log" ]
  [ ! -e "$FAKE_LOG/seed.log" ]
  [[ "$output" != *"lock-conflict-password"* ]]
}

@test "paseo-boot: a non-conflict flock error is FATAL and starts nothing" {
  launcher_env
  cat > "$FAKE_BIN/flock" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$FAKE_BIN/flock"
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=lock-error-password \
    AGENT_DEVBOX_FLOCK_BIN="$FAKE_BIN/flock" \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL: could not acquire the paseo launcher lock (rc=1)"* ]]
  [ ! -e "$FAKE_LOG/gosu.log" ]
  [ ! -e "$FAKE_LOG/paseo.log" ]
  [ ! -e "$FAKE_LOG/seed.log" ]
  [[ "$output" != *"lock-error-password"* ]]
}

@test "paseo-boot: an already-owned home is not chowned" {
  launcher_env
  make_fake_owner_tools
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=owned-password \
    AGENT_DEVBOX_CHOWN_BIN="$FAKE_BIN/chown-fail" \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_LOG/chown-called" ]
  [[ "$output" == *"already owned by $(id -u):$(id -g)"* ]]
  [ -f "$FAKE_LOG/seed.log" ]
  [ -f "$FAKE_LOG/paseo.log" ]
}

@test "paseo-boot: a wrong home owner is chowned by numeric uid:gid and verified" {
  launcher_env
  make_fake_owner_tools
  local want marker="$BATS_TEST_TMPDIR/chowned"
  want="$(id -u):$(id -g)"
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=chown-ok-password \
    AGENT_DEVBOX_STAT_BIN="$FAKE_BIN/stat" \
    AGENT_DEVBOX_CHOWN_BIN="$FAKE_BIN/chown" \
    FAKE_STAT_MARKER="$marker" FAKE_STAT_WRONG_ALL=1 \
    FAKE_WANT="$want" FAKE_WRONG_OWNER="11111:11111" \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$FAKE_LOG/chown.log")" = "$want" ]
  [ "$(sed -n '2p' "$FAKE_LOG/chown.log")" = "--" ]
  [ "$(sed -n '3p' "$FAKE_LOG/chown.log")" = "$FAKE_HOME" ]
  [ "$(wc -l < "$FAKE_LOG/chown.log")" -eq 3 ]
  [[ "$output" == *"chowned paseo home $FAKE_HOME to $want"* ]]
  [ -f "$FAKE_LOG/seed.log" ]
  [ -f "$FAKE_LOG/paseo.log" ]
}

@test "paseo-boot: a failed home chown stops before seed/daemon" {
  launcher_env
  make_fake_owner_tools
  local chosen="home-chown-failure-password"
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD="$chosen" \
    AGENT_DEVBOX_STAT_BIN="$FAKE_BIN/stat" \
    AGENT_DEVBOX_CHOWN_BIN="$FAKE_BIN/chown-fail" \
    FAKE_STAT_WRONG_ALL=1 FAKE_WANT="$(id -u):$(id -g)" \
    FAKE_WRONG_OWNER="54321:54321" \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL: could not chown paseo home"* ]]
  [ -s "$FAKE_LOG/chown.log" ]
  [ ! -e "$FAKE_LOG/seed.log" ]
  [ ! -e "$FAKE_LOG/paseo.log" ]
  [[ "$output" != *"$chosen"* ]]
}

@test "paseo-boot: a failed workspace chown warns and still starts" {
  launcher_env
  make_fake_owner_tools
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=workspace-warn-password \
    AGENT_DEVBOX_STAT_BIN="$FAKE_BIN/stat" \
    AGENT_DEVBOX_CHOWN_BIN="$FAKE_BIN/chown" \
    FAKE_WANT="$(id -u):$(id -g)" FAKE_WRONG_OWNER="54321:54321" \
    FAKE_WRONG_PATH="$FAKE_WORKSPACE" FAKE_CHOWN_FAIL_PATH="$FAKE_WORKSPACE" \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: could not chown workspace $FAKE_WORKSPACE"* ]]
  grep -Fxq "$FAKE_WORKSPACE" "$FAKE_LOG/chown.log"
  [ -f "$FAKE_LOG/seed.log" ]
  [ -f "$FAKE_LOG/paseo.log" ]
}

@test "paseo-boot: a missing workspace only warns and still starts" {
  launcher_env
  rm -rf "$FAKE_WORKSPACE"
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=workspace-missing-password \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: workspace $FAKE_WORKSPACE is missing"* ]]
  [ -f "$FAKE_LOG/seed.log" ]
  [ -f "$FAKE_LOG/paseo.log" ]
}

@test "paseo-boot: a missing paseo home is FATAL before seed/daemon" {
  launcher_env
  rm -rf "$FAKE_HOME"
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=home-missing-password \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL: paseo home $FAKE_HOME is missing"* ]]
  [ ! -e "$FAKE_LOG/seed.log" ]
  [ ! -e "$FAKE_LOG/paseo.log" ]
}

# ---------------------------------------------------------------------------
# P2-B4: /workspace is trusted for the service user's git, as paseo with its
# own HOME, exactly once and without touching root's global config.
# ---------------------------------------------------------------------------

@test "paseo-boot: B4 adds /workspace safe.directory once with paseo HOME" {
  launcher_env
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=b4-first-password \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -Fxc -- '/workspace' "$FAKE_GIT_CONFIG")" -eq 1 ]
  grep -Fxq "git HOME=$FAKE_HOME argv=config --global --add safe.directory /workspace" \
    "$FAKE_LOG/git.log"
  [ -f "$FAKE_LOG/seed.log" ]
  [ -f "$FAKE_LOG/paseo.log" ]
  [[ "$output" != *"b4-first-password"* ]]
}

@test "paseo-boot: B4 second run keeps exactly one /workspace and adds only once" {
  launcher_env
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=b4-idem-1 \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=b4-idem-2 \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -Fxc -- '/workspace' "$FAKE_GIT_CONFIG")" -eq 1 ]
  [ "$(grep -Fc -- '--add safe.directory /workspace' "$FAKE_LOG/git.log")" -eq 1 ]
}

@test "paseo-boot: B4 preserves pre-existing safe.directory entries" {
  launcher_env
  printf '%s\n' '/other' > "$FAKE_GIT_CONFIG"
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=b4-preserve \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  grep -Fxq -- '/other' "$FAKE_GIT_CONFIG"
  [ "$(grep -Fxc -- '/other' "$FAKE_GIT_CONFIG")" -eq 1 ]
  [ "$(grep -Fxc -- '/workspace' "$FAKE_GIT_CONFIG")" -eq 1 ]
}

@test "paseo-boot: B4 a failed git add only warns and still starts" {
  launcher_env
  local chosen="b4-add-failure-password"
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD="$chosen" FAKE_GIT_ADD_FAIL=1 \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: could not add /workspace to git safe.directory"* ]]
  [ -f "$FAKE_LOG/seed.log" ]
  [ -f "$FAKE_LOG/paseo.log" ]
  [[ "$output" != *"$chosen"* ]]
}

@test "paseo-boot: B4 never uses root's HOME or global git config" {
  launcher_env
  local sentinel="$BATS_TEST_TMPDIR/root-gitconfig" before
  printf '%s\n' '[safe]' '	directory = /sentinel' > "$sentinel"
  before="$(cat "$sentinel")"
  run env -i "${LAUNCHER_ENV[@]}" PASEO_PASSWORD=b4-root-untouched \
    bash "$repo/scripts/paseo-boot.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -Fc -- "HOME=$FAKE_HOME" "$FAKE_LOG/git.log")" -eq "$(wc -l < "$FAKE_LOG/git.log")" ]
  ! grep -q "HOME=/root" "$FAKE_LOG/git.log"
  ! grep -q "HOME=$BATS_TEST_TMPDIR" "$FAKE_LOG/git.log"
  [ "$(cat "$sentinel")" = "$before" ]
}

@test "paseo-boot: B4 safe.directory logic lives only in paseo-boot.sh" {
  grep -q 'safe.directory' "$repo/scripts/paseo-boot.sh"
  ! grep -q 'safe.directory' "$repo/scripts/docker-entrypoint.sh"
  ! grep -q 'git config' "$repo/scripts/docker-entrypoint.sh"
  ! grep -q -- '--replace-all safe.directory' "$repo/scripts/paseo-boot.sh"
}

@test "paseo-env: wildcard and localhost canonicalize to concrete loopback" {
  paseo_parse_listen '0.0.0.0:6767'
  [ "$PASEO_LISTEN_CANONICAL" = '0.0.0.0:6767' ]
  [ "$PASEO_PROBE_HOST" = '127.0.0.1' ]
  [ "$PASEO_PORT" = '6767' ]

  paseo_parse_listen '*:6768'
  [ "$PASEO_LISTEN_CANONICAL" = '0.0.0.0:6768' ]
  [ "$PASEO_PROBE_HOST" = '127.0.0.1' ]

  paseo_parse_listen 'localhost:6769'
  [ "$PASEO_LISTEN_CANONICAL" = '127.0.0.1:6769' ]
  [ "$PASEO_PROBE_HOST" = '127.0.0.1' ]
}

@test "paseo-env: bracketed IPv6 keeps brackets and wildcard probes [::1]" {
  paseo_parse_listen '[::1]:7777'
  [ "$PASEO_LISTEN_CANONICAL" = '[::1]:7777' ]
  [ "$PASEO_PROBE_HOST" = '[::1]' ]
  [ "$PASEO_PORT" = '7777' ]

  paseo_parse_listen '[::]:7778'
  [ "$PASEO_LISTEN_CANONICAL" = '[::]:7778' ]
  [ "$PASEO_PROBE_HOST" = '[::1]' ]
}

@test "paseo-env: concrete hosts are preserved and ports normalized" {
  paseo_parse_listen '10.1.2.3:06767'
  [ "$PASEO_LISTEN_CANONICAL" = '10.1.2.3:6767' ]
  [ "$PASEO_PROBE_HOST" = '10.1.2.3' ]
  [ "$PASEO_PORT" = '6767' ]

  paseo_parse_listen '127.0.0.1:6767'
  [ "$PASEO_LISTEN_CANONICAL" = '127.0.0.1:6767' ]
  [ "$PASEO_PROBE_HOST" = '127.0.0.1' ]
}

@test "paseo-env: malformed listen values are rejected" {
  local bad
  for bad in '127.0.0.1' '0.0.0.0:70000' '0.0.0.0:0' '::1:6767' ':6767' \
    '0.0.0.0:' '0.0.0.0:12x7' 'a b:6767' '0.0.0.0:67/67' 'user@host:6767' \
    '[::1:6767' '[::1]:' '[127.0.0.1]:6767'; do
    run paseo_parse_listen "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "paseo-env: web-ui accepts true/false and 1/0 case-insensitively" {
  local value
  for value in true TRUE True 1; do
    paseo_parse_web_ui "$value"
    [ "$PASEO_WEB_UI_CANONICAL" = "true" ]
  done
  for value in false FALSE False 0; do
    paseo_parse_web_ui "$value"
    [ "$PASEO_WEB_UI_CANONICAL" = "false" ]
  done
}

@test "paseo-env: invalid web-ui values are rejected" {
  local bad
  for bad in maybe yes ' true' 2 ''; do
    run paseo_parse_web_ui "$bad"
    [ "$status" -ne 0 ]
  done
}
