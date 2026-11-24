#!/usr/bin/env bats
# docker-data-preflight.sh: Docker-mode fail-closed identity preflight plus the
# empty-HOME first-run init. Offline: fake stat/chown/findmnt seams let every
# case run against temp directories without a real bind mount or uid 1000.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/docker-data-preflight.sh"
  export DATA_ROOT="$BATS_TEST_TMPDIR/data"
  export HOME_DIR="$BATS_TEST_TMPDIR/home"
  export ROOT_DIR="$BATS_TEST_TMPDIR/root"
  export WORKSPACE_DIR="$BATS_TEST_TMPDIR/workspace"
  export SKEL_DIR="$BATS_TEST_TMPDIR/skel"
  export SEED_DIR="$BATS_TEST_TMPDIR/agent-seed"
  export IDENT="$BATS_TEST_TMPDIR/ident"
  export OWNERS="$BATS_TEST_TMPDIR/owners"
  export CHOWN_LOG="$BATS_TEST_TMPDIR/chown.log"
  export MOUNT_MARKER="$BATS_TEST_TMPDIR/mounted"
  export FAKEBIN="$BATS_TEST_TMPDIR/bin"
  export OPENCODE_BIN="$BATS_TEST_TMPDIR/pkg/opencode"
  export CASE_IS_DOCKER="true"
  REAL_STAT="$(command -v stat)"

  mkdir -p \
    "$DATA_ROOT/home" "$DATA_ROOT/root" "$DATA_ROOT/project" \
    "$HOME_DIR" "$ROOT_DIR" "$WORKSPACE_DIR" \
    "$SKEL_DIR" "$SEED_DIR/.config/opencode" "$SEED_DIR/.omo" \
    "$SEED_DIR/.bun/install/cache" \
    "$FAKEBIN" "$BATS_TEST_TMPDIR/pkg"
  printf 'skel-bashrc\n' > "$SKEL_DIR/.bashrc"
  printf '{"agent":"seed"}\n' > "$SEED_DIR/.config/opencode/opencode.json"
  printf 'seed-marker\n' > "$SEED_DIR/.omo/config"
  printf 'cache-bloat\n' > "$SEED_DIR/.bun/install/cache/sentinel"
  printf '#!/bin/sh\necho fake-opencode\n' > "$OPENCODE_BIN"
  chmod +x "$OPENCODE_BIN"
  : > "$MOUNT_MARKER"
  make_fake_tools
}

# make_fake_tools: minimal, stateful seams. `stat` answers identity from $IDENT
# and ownership from $OWNERS (default 0:0); `chown` records its argv and appends
# the new owner; `findmnt` reports mounted iff $MOUNT_MARKER exists.
make_fake_tools() {
  cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
set -u
fmt="${2:-}"
path="${!#}"
case "$fmt" in
  '%d:%i')
    line="$(grep -F -- "$path|" "$IDENT" 2>/dev/null | tail -n 1)"
    if [ -n "$line" ]; then printf '%s\n' "${line##*|}"; else printf '99:99\n'; fi
    ;;
  '%u:%g')
    line="$(grep -F -- "$path|" "$OWNERS" 2>/dev/null | tail -n 1)"
    if [ -n "$line" ]; then printf '%s\n' "${line##*|}"; else printf '0:0\n'; fi
    ;;
  *)
    printf 'unsupported stat format: %s\n' "$fmt" >&2
    exit 2
    ;;
esac
SH
  cat > "$FAKEBIN/chown" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$CHOWN_LOG"
spec=""
targets=()
for arg in "$@"; do
  case "$arg" in
    --|-*) continue ;;
  esac
  if [ -z "$spec" ]; then
    spec="$arg"
  else
    targets+=("$arg")
  fi
done
for target in "${targets[@]}"; do
  printf '%s|%s\n' "$target" "$spec" >> "$OWNERS"
done
SH
  cat > "$FAKEBIN/findmnt" <<'SH'
#!/bin/sh
[ -e "$MOUNT_MARKER" ] && exit 0
exit 1
SH
  chmod +x "$FAKEBIN/stat" "$FAKEBIN/chown" "$FAKEBIN/findmnt"
}

write_ident() { printf '%s|%s\n' "$1" "$2" >> "$IDENT"; }

matching_ids() {
  write_ident "$DATA_ROOT/home" 1:1
  write_ident "$HOME_DIR" 1:1
  write_ident "$DATA_ROOT/root" 2:2
  write_ident "$ROOT_DIR" 2:2
  write_ident "$DATA_ROOT/project" 3:3
  write_ident "$WORKSPACE_DIR" 3:3
}

owner_of() {
  local line
  line="$(grep -F -- "$1|" "$OWNERS" 2>/dev/null | tail -n 1)"
  if [ -n "$line" ]; then
    printf '%s\n' "${line##*|}"
  else
    printf '0:0\n'
  fi
}

run_preflight() {
  local env_args=(
    "IS_DOCKER=$CASE_IS_DOCKER"
    "PATH=$FAKEBIN:/usr/bin:/bin"
    "AGENT_DEVBOX_DATA_ROOT=$DATA_ROOT"
    "AGENT_DEVBOX_HOME_DIR=$HOME_DIR"
    "AGENT_DEVBOX_ROOT_DIR=$ROOT_DIR"
    "AGENT_DEVBOX_WORKSPACE_DIR=$WORKSPACE_DIR"
    "AGENT_DEVBOX_SKEL_DIR=$SKEL_DIR"
    "AGENT_SEED_DIR=$SEED_DIR"
    "AGENT_DEVBOX_OPENCODE_BIN=$OPENCODE_BIN"
    "AGENT_DEVBOX_STAT_BIN=$FAKEBIN/stat"
    "AGENT_DEVBOX_CHOWN_BIN=$FAKEBIN/chown"
    "AGENT_DEVBOX_FINDMNT_BIN=$FAKEBIN/findmnt"
    "AGENT_DEVBOX_GOSU_BIN="
    "IDENT=$IDENT" "OWNERS=$OWNERS" "CHOWN_LOG=$CHOWN_LOG"
    "MOUNT_MARKER=$MOUNT_MARKER"
  )
  run env "${env_args[@]}" bash "$SCRIPT"
}

assert_no_writes() {
  [ ! -e "$HOME_DIR/paseo" ]
  [ ! -e "$CHOWN_LOG" ]
  [ ! -e "$ROOT_DIR/.opencode" ]
}

@test "identity match initializes the empty home tree" {
  matching_ids
  run_preflight
  [ "$status" -eq 0 ]
  [ -f "$HOME_DIR/paseo/.bashrc" ]
  [ "$(cat "$HOME_DIR/paseo/.bashrc")" = "skel-bashrc" ]
  [ -f "$HOME_DIR/paseo/.config/opencode/opencode.json" ]
  [ -f "$HOME_DIR/paseo/.omo/config" ]
  [ -d "$WORKSPACE_DIR" ]
  [ "$(owner_of "$HOME_DIR/paseo")" = "1000:1000" ]
  [ "$(owner_of "$ROOT_DIR")" = "0:0" ]
  [ "$("$REAL_STAT" -c '%a' "$ROOT_DIR")" = "700" ]
  [ -L "$ROOT_DIR/.opencode/bin/opencode" ]
  [ "$(readlink "$ROOT_DIR/.opencode/bin/opencode")" = "$OPENCODE_BIN" ]
}

@test "identity mismatch fails closed with path, expected and actual identity" {
  matching_ids
  write_ident "$HOME_DIR" 9:9
  run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"data-disk identity mismatch"* ]]
  [[ "$output" == *"$HOME_DIR"* ]]
  [[ "$output" == *"expected=1:1"* ]]
  [[ "$output" == *"actual=9:9"* ]]
  assert_no_writes
}

@test "missing baseline directory fails closed before any write" {
  matching_ids
  rm -rf "$DATA_ROOT"
  run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"baseline bind missing"* ]]
  assert_no_writes
}

@test "baseline that is not a mountpoint fails closed before any write" {
  matching_ids
  rm -f "$MOUNT_MARKER"
  run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a mountpoint"* ]]
  assert_no_writes
}

@test "missing target fails closed before any write" {
  matching_ids
  rm -rf "$WORKSPACE_DIR"
  run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"target missing"* ]]
  [[ "$output" == *"$WORKSPACE_DIR"* ]]
  assert_no_writes
}

@test "a failed preflight leaves pre-existing contents untouched" {
  matching_ids
  write_ident "$ROOT_DIR" 8:8
  printf 'keep-me\n' > "$ROOT_DIR/sentinel"
  printf 'workspace-keep\n' > "$WORKSPACE_DIR/sentinel"
  run_preflight
  [ "$status" -ne 0 ]
  [ "$(cat "$ROOT_DIR/sentinel")" = "keep-me" ]
  [ "$(cat "$WORKSPACE_DIR/sentinel")" = "workspace-keep" ]
  [ ! -e "$HOME_DIR/paseo" ]
  [ ! -e "$CHOWN_LOG" ]
}

@test "empty-HOME init is idempotent and never overwrites user files" {
  matching_ids
  run_preflight
  [ "$status" -eq 0 ]
  local calls_after_first
  calls_after_first="$(wc -l < "$CHOWN_LOG")"
  printf 'user-edit\n' > "$HOME_DIR/paseo/.bashrc"

  run_preflight
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME_DIR/paseo/.bashrc")" = "user-edit" ]
  [ "$(wc -l < "$CHOWN_LOG")" -eq "$calls_after_first" ]
  [ "$(owner_of "$HOME_DIR/paseo")" = "1000:1000" ]
  [ -L "$ROOT_DIR/.opencode/bin/opencode" ]
  [ "$(cat "$HOME_DIR/paseo/.config/opencode/opencode.json")" = '{"agent":"seed"}' ]
}

@test "agent seed copies only .config/opencode and .omo, never build caches" {
  matching_ids
  run_preflight
  [ "$status" -eq 0 ]
  [ -f "$HOME_DIR/paseo/.config/opencode/opencode.json" ]
  [ -f "$HOME_DIR/paseo/.omo/config" ]
  [ ! -e "$HOME_DIR/paseo/.bun" ]
  [ ! -e "$HOME_DIR/paseo/.bun/install/cache/sentinel" ]
}

@test "non-Docker mode is a silent no-op even with a mismatch" {
  CASE_IS_DOCKER=false
  matching_ids
  write_ident "$HOME_DIR" 9:9
  run_preflight
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_writes
}

@test "compose mounts the whole home tree from an explicit DATA_DIR" {
  local compose="$REPO_ROOT/docker-compose.yml"
  grep -Fq 'source: "${DATA_DIR:?set DATA_DIR}/home"' "$compose"
  grep -Fq 'target: /home' "$compose"
  grep -Fq 'source: "${DATA_DIR:?set DATA_DIR}/root"' "$compose"
  grep -Fq 'target: /root' "$compose"
  grep -Fq 'source: "${DATA_DIR:?set DATA_DIR}/project"' "$compose"
  grep -Fq 'target: /workspace' "$compose"
  grep -Fq 'target: /run/agent-devbox/data' "$compose"
  grep -Fq 'read_only: true' "$compose"
  [ "$(grep -Fc 'create_host_path: false' "$compose")" -eq 4 ]
  if grep -Fq 'DATA_DIR:-./data' "$compose"; then
    echo "compose must not silently fall back to ./data"
    return 1
  fi
}

@test "1Panel compose mirrors the three targets and the baseline bind" {
  local compose="$REPO_ROOT/1panel/agent-devbox/latest/docker-compose.yml"
  grep -Fq './data/home:/home' "$compose"
  grep -Fq './data/root:/root' "$compose"
  grep -Fq './data/project:/workspace' "$compose"
  grep -Fq './data:/run/agent-devbox/data:ro' "$compose"
}

@test "WSL boot never sources the Docker preflight" {
  run grep -F 'docker-data-preflight' "$REPO_ROOT/scripts/wsl-boot.sh"
  [ "$status" -ne 0 ]
}
