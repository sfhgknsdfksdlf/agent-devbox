#!/usr/bin/env bats
# Contract for scripts/wsl-session-mount.sh and config/profile.d/zz-agent-devbox-session-mount.sh
# (plan .omo/plans/wsl-session-mount.md §4.1/§4.2): a login-shell helper that attaches the
# persistent data disk to the WSL session mount namespace (0 ok / 2 usage / 3 skip / 4 failed),
# plus the POSIX profile.d shim that calls it only for interactive root TTY logins and never
# exits the login shell. Hermetic: id/sleep/mkdir/blkid/mount/mountpoint/findmnt/stat are PATH
# shims, so no block device, /etc, /mnt, /home or /root is ever touched.
#
# Cases use the standard bats `@test "..." {` declaration, matching the other suites; this file
# is not a bash script (`bash -n` does not apply), and `bats --count` sees every case.
# shellcheck disable=SC2016,SC2030,SC2031

# Baseline PATH captured before any shim dir is prepended; static guards use it for real tools.
: "${AGENT_DEVBOX_TEST_REAL_PATH:=$PATH}"
export AGENT_DEVBOX_TEST_REAL_PATH

setup() {
  TMP="$(mktemp -d)"
  BINDIR="$TMP/bin"
  CALL_LOG="$TMP/calls.log"
  MARKDIR="$TMP/mark"
  IDDIR="$TMP/ids"
  REAL_PATH="$AGENT_DEVBOX_TEST_REAL_PATH"
  export TMP BINDIR CALL_LOG MARKDIR IDDIR REAL_PATH

  export SCRIPT="$BATS_TEST_DIRNAME/../../scripts/wsl-session-mount.sh"
  export HOOK="$BATS_TEST_DIRNAME/../../config/profile.d/zz-agent-devbox-session-mount.sh"

  # Same overrides the helper documents for internal/test use (§4.1).
  export AGENT_DEVBOX_CONF="$TMP/conf"
  export AGENT_DEVBOX_DATADIR="$TMP/data"
  export AGENT_DEVBOX_SESSION_TARGETS="$TMP/t/home $TMP/t/root $TMP/t/workspace"
  export AGENT_DEVBOX_SESSION_WAIT=1

  # Shim inputs: root by default, private propagation, a matching UUID, rw options.
  export ID_UID=0
  export PROP=private
  export UUID_OUT=test-uuid-1234
  export OPTS=rw
  export UUID_DEV=/dev/fakedisk1
  export LABEL_DEV=/dev/fakedisk1

  # Never inherit the image's Docker marker or a stray label/helper override.
  unset IS_DOCKER AGENT_DEVBOX_DATA_LABEL AGENT_DEVBOX_SESSION_MOUNT_BIN
  unset MOUNT_FAIL MOUNT_RACE

  mkdir -p "$BINDIR" "$MARKDIR" "$IDDIR" \
    "$TMP/t/home" "$TMP/t/root" "$TMP/t/workspace" \
    "$AGENT_DEVBOX_DATADIR/home" "$AGENT_DEVBOX_DATADIR/root" "$AGENT_DEVBOX_DATADIR/workspace"
  : > "$CALL_LOG"
  : > "$AGENT_DEVBOX_DATADIR/.initialized"

  write_conf
  install_shims
  export PATH="$BINDIR:$PATH"
  hash -r
}

teardown() {
  if [ -n "${TMP:-}" ]; then
    rm -rf "$TMP"
  fi
}

# write_conf [mntname] [label] [uuid]: the 6-key file the Windows installer writes.
write_conf() {
  local mntname="${1:-devbox-data}"
  local label="${2:-devbox-data}"
  local uuid="${3:-test-uuid-1234}"
  {
    printf 'DATA_VHDX="D:\\WSL\\agent-devbox\\data.vhdx"\n'
    printf 'DATA_UUID="%s"\n' "$uuid"
    printf 'DATA_LABEL="%s"\n' "$label"
    printf 'PASEO_PASSWORD="s3cret-do-not-leak"\n'
    printf 'DATA_MNTNAME="%s"\n' "$mntname"
    printf 'DATA_DISTRO="agent-devbox"\n'
  } > "$AGENT_DEVBOX_CONF"
}

# Every OS probe the helper is allowed to make is replaced here; each shim is documented inline.
install_shims() {
  # id: the only question is "is the session user root?" (H4).
  cat > "$BINDIR/id" <<'SH'
#!/bin/sh
printf '%s\n' "${ID_UID:-0}"
SH

  # sleep: the bounded device wait must never cost real time in tests (H11).
  cat > "$BINDIR/sleep" <<'SH'
#!/bin/sh
exit 0
SH

  # mkdir: pass through to the real binary, so temp dirs keep working (H18).
  cat > "$BINDIR/mkdir" <<'SH'
#!/bin/sh
exec /bin/mkdir "$@"
SH

  # blkid: resolves -U <uuid> / -L <label> / -o device -t UUID=...|LABEL=... from
  # UUID_DEV / LABEL_DEV. A multi-line value models two candidate devices (ambiguity,
  # H13); no match exits 2 exactly like the real tool. Every call is recorded.
  cat > "$BINDIR/blkid" <<'SH'
#!/bin/sh
printf 'blkid %s\n' "$*" >> "$CALL_LOG"
want_uuid=0
want_label=0
prev=""
for a in "$@"; do
  case "$a" in
    UUID=*) want_uuid=1 ;;
    LABEL=*) want_label=1 ;;
  esac
  if [ "$prev" = "-U" ]; then want_uuid=1; fi
  if [ "$prev" = "-L" ]; then want_label=1; fi
  prev="$a"
done
if [ "$want_label" = 1 ]; then
  [ -n "${LABEL_DEV:-}" ] || exit 2
  printf '%s\n' "$LABEL_DEV"
  exit 0
fi
if [ "$want_uuid" = 1 ]; then
  [ -n "${UUID_DEV:-}" ] || exit 2
  printf '%s\n' "$UUID_DEV"
  exit 0
fi
exit 2
SH

  # mount: records argv. `-t ext4` creates the mounted marker for the target (MOUNT_FAIL
  # fails without mounting; MOUNT_RACE mounts but still exits 1, modelling a concurrent
  # mount that wins). `--bind` / `-o bind` creates the target marker AND copies the
  # source's stat identity, so stat(dst) == stat(src) exactly like a real bind (H2/H17).
  cat > "$BINDIR/mount" <<'SH'
#!/bin/sh
printf 'mount %s\n' "$*" >> "$CALL_LOG"
key() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
mark() { /bin/mkdir -p "$MARKDIR"; : > "$MARKDIR/$(key "$1")"; }
bind=0
ext4=0
prev=""
for a in "$@"; do
  case "$a" in
    --bind) bind=1 ;;
    bind) if [ "$prev" = "-o" ]; then bind=1; fi ;;
    ext4) if [ "$prev" = "-t" ]; then ext4=1; fi ;;
  esac
  prev="$a"
done
src=""
tgt=""
for a in "$@"; do
  src="$tgt"
  tgt="$a"
done
if [ "$bind" = 1 ]; then
  mark "$tgt"
  /bin/mkdir -p "$IDDIR"
  sf="$IDDIR/$(key "$src")"
  df="$IDDIR/$(key "$tgt")"
  if [ -f "$sf" ]; then
    cp "$sf" "$df"
  else
    printf '1:%s\n' "$(key "$src")" > "$df"
  fi
  exit 0
fi
if [ "$ext4" = 1 ]; then
  if [ "${MOUNT_RACE:-0}" = 1 ]; then
    mark "$tgt"
    exit 1
  fi
  if [ "${MOUNT_FAIL:-0}" = 1 ]; then
    exit 1
  fi
  mark "$tgt"
  exit 0
fi
mark "$tgt"
exit 0
SH

  # mountpoint -q: true iff the mount shim created the path's marker.
  cat > "$BINDIR/mountpoint" <<'SH'
#!/bin/sh
key() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
p=""
for a in "$@"; do
  case "$a" in
    -*) ;;
    *) p="$a" ;;
  esac
done
if [ -n "$p" ] && [ -e "$MARKDIR/$(key "$p")" ]; then
  exit 0
fi
exit 1
SH

  # findmnt: -T/--target reports PROP (default private, H1); --mountpoint/-M requires the
  # marker then reports UUID_OUT for -o UUID, OPTS (rw) for -o OPTIONS; combined short
  # flags such as `-rno UUID` are accepted. -o TARGET echoes the target.
  cat > "$BINDIR/findmnt" <<'SH'
#!/bin/sh
key() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
want=""
target=""
mnt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) shift; want="${1:-}" ;;
    -*o) shift; want="${1:-}" ;;
    -T|--target) shift; target="${1:-}" ;;
    --target=*) target="${1#--target=}" ;;
    --mountpoint|-M) shift; mnt="${1:-}" ;;
    --mountpoint=*) mnt="${1#--mountpoint=}" ;;
    --output=*) want="${1#--output=}" ;;
    -*) ;;
    *) target="$1" ;;
  esac
  shift
done
if [ -n "$mnt" ] && [ ! -e "$MARKDIR/$(key "$mnt")" ]; then
  exit 1
fi
case "$want" in
  UUID) printf '%s\n' "${UUID_OUT:-}" ;;
  OPTIONS) printf '%s\n' "${OPTS:-rw}" ;;
  PROPAGATION) printf '%s\n' "${PROP:-private}" ;;
  TARGET) printf '%s\n' "${target:-/}" ;;
  *) printf '%s\n' "${target:-/}" ;;
esac
exit 0
SH

  # stat -c %d:%i: a stable per-path identity map. A bind copies the source entry, so a
  # correctly bound target reports exactly the source's id (H12).
  cat > "$BINDIR/stat" <<'SH'
#!/bin/sh
key() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
last=""
for a in "$@"; do
  last="$a"
done
if [ -z "$last" ]; then
  printf '0:0\n'
  exit 0
fi
f="$IDDIR/$(key "$last")"
if [ -f "$f" ]; then
  cat "$f"
else
  printf '1:%s\n' "$(key "$last")"
fi
SH

  chmod +x "$BINDIR"/*
}

# --- call-log assertions (direct grep, so $output survives) -----------------

assert_log_has() { grep -Fq -- "$1" "$CALL_LOG"; }
assert_log_lacks() { ! grep -Fq -- "$1" "$CALL_LOG"; }
assert_no_mount_calls() { ! grep -Eq '^mount ' "$CALL_LOG"; }
bind_count() { grep -c '^mount --bind' "$CALL_LOG" 2>/dev/null || true; }

# --- stat-map helpers shared with the shims --------------------------------

path_key() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

# mark_path <path>: make mountpoint -q <path> succeed.
mark_path() {
  mkdir -p "$MARKDIR"
  : > "$MARKDIR/$(path_key "$1")"
}

# bind_id <src> <dst>: make stat(dst) report stat(src), as a real bind would.
bind_id() {
  local id
  if [ -f "$IDDIR/$(path_key "$1")" ]; then
    id="$(cat "$IDDIR/$(path_key "$1")")"
  else
    id="1:$(path_key "$1")"
  fi
  mkdir -p "$IDDIR"
  printf '%s\n' "$id" > "$IDDIR/$(path_key "$2")"
}

# fake helper for the profile.d shim: records calls and succeeds.
make_fake_helper() {
  HELPER_LOG="$TMP/helper.log"
  export HELPER_LOG
  : > "$HELPER_LOG"
  cat > "$TMP/fake-helper" <<'SH'
#!/bin/sh
printf 'helper %s\n' "$*" >> "$HELPER_LOG"
exit 0
SH
  chmod +x "$TMP/fake-helper"
  export AGENT_DEVBOX_SESSION_MOUNT_BIN="$TMP/fake-helper"
}

# ===========================================================================
# Guards: never touch the disk from contexts where it cannot work.
# ===========================================================================

@test "test_docker_mode_is_a_noop" {
  run env IS_DOCKER=true "$SCRIPT" --force
  [ "$status" -eq 3 ]
  [ ! -s "$CALL_LOG" ]
  [[ "$output" != *"已把持久数据盘接入当前会话"* ]]
}

@test "test_missing_conf_is_skipped" {
  rm -f "$AGENT_DEVBOX_CONF"
  run "$SCRIPT" --force
  [ "$status" -eq 3 ]
  [ ! -s "$CALL_LOG" ]
  [[ "$output" != *"已把持久数据盘接入当前会话"* ]]
}

@test "test_non_root_session_is_skipped" {
  run env ID_UID=1000 "$SCRIPT" --force
  [ "$status" -eq 3 ]
  [ ! -s "$CALL_LOG" ]
}

@test "test_non_tty_without_force_is_skipped" {
  run "$SCRIPT" </dev/null
  [ "$status" -eq 3 ]
  assert_no_mount_calls
}

@test "test_non_tty_with_force_proceeds" {
  run "$SCRIPT" --force </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"已把持久数据盘接入当前会话：/home /root /workspace"* ]]
  assert_log_has '-t ext4'
}

# Regression: the helper runs as its own script, so its `$-` NEVER contains `i`.
# An earlier version also required interactivity there, so the real hook (which
# calls the helper WITHOUT --force from an interactive login shell) always got
# exit 3. The TTY gate must be `[ -t 0 ]` alone (H7); prove it under a real pty.
@test "test_tty_without_force_proceeds" {
  if ! command -v script >/dev/null 2>&1; then
    skip "script not available"
  fi
  run script -qec "$SCRIPT" /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"已把持久数据盘接入当前会话：/home /root /workspace"* ]]
  assert_log_has '-t ext4'
}

@test "test_unknown_argument_is_a_usage_error" {
  run "$SCRIPT" --force --bogus
  [ "$status" -eq 2 ]
  assert_no_mount_calls
}

# ===========================================================================
# Device resolution: missing / label fallback / ambiguity.
# ===========================================================================

@test "test_missing_device_warns_and_fails_without_mounting" {
  run env UUID_DEV= LABEL_DEV= "$SCRIPT" --force
  [ "$status" -eq 4 ]
  [[ "$output" == *"mount-datadisk.cmd"* ]]
  assert_no_mount_calls
}

# Reviewer N-3: a non-numeric wait must fall back to the internal default instead
# of reaching the `[ "$attempt" -ge "$SESSION_WAIT" ]` arithmetic test (which
# would error and spin the loop forever). The sleep shim makes the bounded wait
# instant, so this asserts the fallback exits rather than looping.
@test "test_non_numeric_wait_is_bounded" {
  run env AGENT_DEVBOX_SESSION_WAIT=abc UUID_DEV= LABEL_DEV= "$SCRIPT" --force
  [ "$status" -eq 4 ]
  [[ "$output" == *"mount-datadisk.cmd"* ]]
  assert_no_mount_calls
}

@test "test_label_fallback_resolves_the_device" {
  run env UUID_DEV= LABEL_DEV=/dev/fakedisk-label "$SCRIPT" --force
  [ "$status" -eq 0 ]
  assert_log_has 'LABEL='
  assert_log_has '-t ext4'
}

@test "test_ambiguous_devices_fail_closed" {
  export UUID_DEV="$(printf '/dev/fakedisk1\n/dev/fakedisk2')"
  run "$SCRIPT" --force
  [ "$status" -eq 4 ]
  [[ "$output" == *"有多块设备匹配数据盘标识"* ]]
  assert_no_mount_calls
}

# ===========================================================================
# Happy path, race, failure and idempotence.
# ===========================================================================

@test "test_happy_path_mounts_then_binds_in_order" {
  run "$SCRIPT" --force
  [ "$status" -eq 0 ]
  local out="$output"
  [ "$(printf '%s\n' "$out" | grep -Fxc '已把持久数据盘接入当前会话：/home /root /workspace')" -eq 1 ]

  local first_mount last_blkid first_line
  first_mount="$(grep -n '^mount ' "$CALL_LOG" | head -n 1 | cut -d: -f1)"
  last_blkid="$(grep -n '^blkid ' "$CALL_LOG" | tail -n 1 | cut -d: -f1)"
  [ -n "$first_mount" ]
  [ -n "$last_blkid" ]
  [ "$last_blkid" -lt "$first_mount" ]
  first_line="$(sed -n "${first_mount}p" "$CALL_LOG")"
  [[ "$first_line" == *"-t ext4"* ]]
  [[ "$first_line" == *"-o rw"* ]]
  [ "$(bind_count)" -eq 3 ]

  local leaf src dst
  for leaf in home root workspace; do
    src="$(stat -c '%d:%i' "$AGENT_DEVBOX_DATADIR/$leaf")"
    dst="$(stat -c '%d:%i' "$TMP/t/$leaf")"
    [ "$src" = "$dst" ]
  done
}

@test "test_uuid_mismatch_after_mount_fails" {
  export UUID_OUT=00000000-dead-beef
  run "$SCRIPT" --force
  [ "$status" -eq 4 ]
  [[ "$output" == *"数据盘校验失败"* ]]
  [ "$(bind_count)" -eq 0 ]
}

@test "test_mount_failure_fails_without_binding" {
  export MOUNT_FAIL=1
  run "$SCRIPT" --force
  [ "$status" -eq 4 ]
  [[ "$output" == *"数据盘挂载失败"* ]]
  [ "$(bind_count)" -eq 0 ]
}

@test "test_mount_race_recheck_wins" {
  export MOUNT_RACE=1
  run "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ "$(bind_count)" -eq 3 ]
}

@test "test_already_mounted_fast_path_is_silent_and_calls_nothing" {
  local leaf
  mark_path "$AGENT_DEVBOX_DATADIR"
  for leaf in home root workspace; do
    mark_path "$AGENT_DEVBOX_DATADIR/$leaf"
    mark_path "$TMP/t/$leaf"
    bind_id "$AGENT_DEVBOX_DATADIR/$leaf" "$TMP/t/$leaf"
  done
  run "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_mount_calls
}

@test "test_second_run_is_idempotent_and_silent" {
  run "$SCRIPT" --force
  [ "$status" -eq 0 ]
  : > "$CALL_LOG"
  run "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_mount_calls
}

# Regression (reviewer B1): the data disk can already be mounted in this
# namespace while /home /root /workspace are still unbound. The helper must
# detect the existing mount and bind only, never issue a second `-t ext4`.
@test "test_already_mounted_but_unbound_does_not_remount" {
  mark_path "$AGENT_DEVBOX_DATADIR"
  run "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ "$(grep -c '^mount .*\-t ext4' "$CALL_LOG" || true)" -eq 0 ]
  [ "$(bind_count)" -eq 3 ]
}

# Regression (reviewer B1): stacked mounts of the same device make findmnt
# print the same UUID twice; that is not a UUID mismatch. The helper must
# de-duplicate (sort -u) instead of failing closed.
@test "test_stacked_same_uuid_is_not_a_mismatch" {
  write_conf devbox-data devbox-data same-uuid
  mark_path "$AGENT_DEVBOX_DATADIR"
  export UUID_OUT="$(printf 'same-uuid\nsame-uuid')"
  run "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ "$(grep -c '^mount .*\-t ext4' "$CALL_LOG" || true)" -eq 0 ]
  [ "$(bind_count)" -eq 3 ]
}

# ===========================================================================
# Preconditions: propagation, path validation, initialization marker.
# ===========================================================================

@test "test_shared_parent_propagation_is_refused" {
  export PROP=shared
  run "$SCRIPT" --force
  [ "$status" -eq 4 ]
  [[ "$output" == *"shared 传播"* ]]
  assert_no_mount_calls
}

@test "test_mntname_with_slash_is_rejected" {
  write_conf 'bad/name'
  run "$SCRIPT" --force
  [ "$status" -eq 4 ]
  assert_no_mount_calls
}

@test "test_mntname_dotdot_is_rejected" {
  write_conf '..'
  run "$SCRIPT" --force
  [ "$status" -eq 4 ]
  assert_no_mount_calls
}

# Reviewer N-4: "wsl" is the shared cross-distro mount directory, so the helper
# rejects it by NAME before resolving $AGENT_DEVBOX_DATADIR. AGENT_DEVBOX_DATADIR
# stays the temp dir, so nothing real under /mnt/wsl is ever touched; the bare
# string check plus zero mount calls is the contract.
@test "test_mntname_wsl_is_rejected" {
  write_conf wsl
  run "$SCRIPT" --force
  [ "$status" -eq 4 ]
  [[ "$output" == *"挂载名不合法"* ]]
  assert_no_mount_calls
}

@test "test_missing_initialized_marker_skips_binds" {
  rm -f "$AGENT_DEVBOX_DATADIR/.initialized"
  run "$SCRIPT" --force
  [ "$status" -eq 4 ]
  [[ "$output" == *"尚未完成初始化"* ]]
  [ "$(bind_count)" -eq 0 ]
}

# Regression (reviewer B1): an uninitialized first run may mount the disk, so
# the retry after seed must NOT stack a second `-t ext4`. Exactly one mount
# across both runs, then the three binds.
@test "test_uninitialized_then_initialized_recovers_without_stacking" {
  rm -f "$AGENT_DEVBOX_DATADIR/.initialized"
  run "$SCRIPT" --force
  [ "$status" -eq 4 ]
  [ "$(bind_count)" -eq 0 ]
  : > "$AGENT_DEVBOX_DATADIR/.initialized"
  run "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ "$(grep -c '^mount .*\-t ext4' "$CALL_LOG")" -eq 1 ]
  [ "$(bind_count)" -eq 3 ]
}

# ===========================================================================
# Static guards: helper safety contract and POSIX profile.d shim.
# ===========================================================================

@test "test_static_helper_safety_contract" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run env PATH="$REAL_PATH" stat -c '%a' "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "755" ]

  run grep -Fq -- '-o rw' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -Fq -- 'unset PASEO_PASSWORD' "$SCRIPT"
  [ "$status" -eq 0 ]

  local tok
  for tok in 'wsl.exe' 'schtasks' 'wsl -d' '--unmount' '/mnt/wsl' 'mkfs'; do
    run grep -Fq -- "$tok" "$SCRIPT"
    [ "$status" -ne 0 ]
  done
}

@test "test_static_hook_contract" {
  [ -f "$HOOK" ]
  run sh -n "$HOOK"
  [ "$status" -eq 0 ]

  run grep -Fq -- 'IS_DOCKER' "$HOOK"
  [ "$status" -eq 0 ]
  run grep -Fq -- '*i*' "$HOOK"
  [ "$status" -eq 0 ]
  run grep -Fq -- '-t 0' "$HOOK"
  [ "$status" -eq 0 ]
  run grep -Fq -- '/usr/local/bin/wsl-session-mount.sh' "$HOOK"
  [ "$status" -eq 0 ]
  run grep -Fq -- 'return 0' "$HOOK"
  [ "$status" -eq 0 ]

  run grep -Fq -- 'exit' "$HOOK"
  [ "$status" -ne 0 ]
  run grep -Fq -- 'wsl.exe' "$HOOK"
  [ "$status" -ne 0 ]

  # run-parts only runs *.sh in sort order: zz- must come after agent-devbox.sh (H14).
  run bash -c "printf '%s\n' agent-devbox.sh zz-agent-devbox-session-mount.sh | sort | tail -n 1"
  [ "$status" -eq 0 ]
  [ "$output" = "zz-agent-devbox-session-mount.sh" ]
}

# ===========================================================================
# Hook behaviour: no helper call without an interactive TTY (H7).
# ===========================================================================

@test "test_hook_skips_non_interactive_shell" {
  [ -f "$HOOK" ]
  make_fake_helper
  run bash -c '. "$HOOK"; echo HOOK_SOURCED'
  [ "$status" -eq 0 ]
  [[ "$output" == *"HOOK_SOURCED"* ]]
  [ ! -s "$HELPER_LOG" ]
}

@test "test_hook_skips_docker_mode" {
  [ -f "$HOOK" ]
  make_fake_helper
  # A real pty, so the hook passes $- and -t 0 and is stopped by the Docker
  # guard itself (a plain non-interactive shell would return earlier).
  run env IS_DOCKER=true script -qec "bash -ic '. \"$HOOK\"'" /dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$HELPER_LOG" ]
}

# The hook must actually invoke the helper under an interactive pty (root,
# configured, non-Docker); a non-TTY guard regression would silently skip it.
@test "test_hook_calls_helper_on_interactive_pty" {
  [ -f "$HOOK" ]
  make_fake_helper
  run script -qec "bash -ic '. \"$HOOK\"'" /dev/null
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$HELPER_LOG")" -eq 1 ]
}
