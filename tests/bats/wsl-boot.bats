#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
# wsl-boot.sh: pins the attach + PURE-LINUX data-disk mount chain.
#
# Boot hands the disk over by exactly ONE bounded interop call — a bare attach
# (`wsl.exe --mount --vhd <path> --bare`), skipped when the device is already
# present — and everything after it is Linux: the mountpoint derives from
# load_conf() (AGENT_DEVBOX_DATADIR > /mnt/$DATA_MNTNAME), the device resolves by
# UUID via `blkid -U`, and `mount -t ext4` does the mount. There is no scheduled
# task and no re-entrant call into Windows from [boot]; the install-dir batch
# script is an on-demand repair path only. Failure is expressed as a bilingual
# MAINTENANCE MOTD whose commands can be pasted into a WSL terminal (plus a
# PowerShell fallback), never by re-launching the Windows installer.
#
# The script is safe to source (BASH_SOURCE guard) and reads its paths from
# AGENT_DEVBOX_* env vars AT SOURCE TIME, so every case runs in an isolated
# subshell against a temp conf/log/datadir/motd plus a fake bin dir prepended to
# PATH. findmnt/sleep/blkid/mount/mkdir are all shimmed; a shim "mounts" by
# creating the mounted-marker, so no real block device is required.
#
# SCRIPT is overridable via WSL_BOOT_SH so this same suite can be pointed at an
# old revision (git show HEAD:scripts/wsl-boot.sh) to prove it can actually fail.

setup() {
  TMP="$(mktemp -d)"
  export TMP
  export SCRIPT="${WSL_BOOT_SH:-$BATS_TEST_DIRNAME/../../scripts/wsl-boot.sh}"
  export BINDIR="$TMP/bin"
  export MOUNT_MARKER="$TMP/mounted.marker"
  export DEVICE_FLAG="$TMP/device.flag"
  export CALL_LOG="$TMP/calls.log"
  export WSL_LOG="$TMP/wsl.log"
  export VHDX="$TMP/data.vhdx"
  export AGENT_DEVBOX_CONF="$TMP/agent-devbox.conf"
  export AGENT_DEVBOX_LOG="$TMP/boot.log"
  export AGENT_DEVBOX_DATADIR="$TMP/data"
  export AGENT_DEVBOX_MOTD="$TMP/motd"
  export AGENT_DEVBOX_DOCKERD_PID="$TMP/dockerd.pid"
  export AGENT_DEVBOX_DOCKERD_LOG="$TMP/dockerd.log"
  export AGENT_DEVBOX_DOCKERD_LOG_MAX=10
  export AGENT_DEVBOX_PASEO_LOG="$TMP/paseo.log"
  export AGENT_DEVBOX_PASEO_PID="$TMP/paseo.pid"
  export AGENT_DEVBOX_PASEO_BOOT_BIN="$TMP/paseo-boot.sh"
  export AGENT_DEVBOX_PASEO_HEALTH_URL="http://127.0.0.1:6767/api/health"
  export AGENT_DEVBOX_DOCKER_SOCK="$TMP/docker.sock"
  export AGENT_DEVBOX_DOCKER_BIN="$BINDIR/docker"
  export AGENT_DEVBOX_DOCKERD_BIN="$BINDIR/dockerd"
  export AGENT_DEVBOX_CURL_BIN="$BINDIR/curl"
  export AGENT_DEVBOX_SETSID_BIN="$BINDIR/setsid"
  export AGENT_DEVBOX_PROC_FS="$TMP/proc"
  export AGENT_DEVBOX_OVERLAY_MARKER="$TMP/overlay.marker"
  export AGENT_DEVBOX_READY_TIMEOUT=30
  export AGENT_DEVBOX_READY_POLL_MS=2000
  export AGENT_DEVBOX_PASEO_UID="$(id -u)"
  export AGENT_DEVBOX_BOOT_ID="boot-test"
  export AGENT_DEVBOX_NODE_BIN="$TMP/node-bin"
  export AGENT_DEVBOX_OPENCODE_BIN="$TMP/no-opencode"
  export LAUNCHED_PASEO="$TMP/launched.paseo"
  export LAUNCHED_DOCKERD="$TMP/launched.dockerd"
  export CLOCK_COUNT="$TMP/clock.count"
  export BOUND="$TMP/bound"
  export DOCKERD_PIDFILE="$AGENT_DEVBOX_DOCKERD_PID"
  export PASEO_PIDFILE="$AGENT_DEVBOX_PASEO_PID"
  mkdir -p "$BINDIR" "$AGENT_DEVBOX_DATADIR" "$AGENT_DEVBOX_PROC_FS/sys/kernel/random"
  printf 'boot-test\n' > "$AGENT_DEVBOX_PROC_FS/sys/kernel/random/boot_id"
  : > "$CALL_LOG"
  : > "$WSL_LOG"
  : > "$AGENT_DEVBOX_LOG"
  export PATH="$BINDIR:$PATH"
}

teardown() { rm -rf "$TMP"; }

# base_shims: findmnt reports "mounted" iff the marker exists; sleep is instant;
# blkid resolves the UUID to a fake device; mount records its argv and "mounts";
# mkdir is a no-op (the script only needs the mountpoint to appear in findmnt).
base_shims() {
  cat > "$BINDIR/findmnt" <<'SH'
#!/bin/sh
if [ -e "$MOUNT_MARKER" ]; then
  exit 0
fi
exit 1
SH
  cat > "$BINDIR/sleep" <<'SH'
#!/bin/sh
exit 0
SH
  cat > "$BINDIR/blkid" <<'SH'
#!/bin/sh
echo /dev/fakedev
exit 0
SH
  cat > "$BINDIR/mount" <<'SH'
#!/bin/sh
echo "mount $*" >> "$CALL_LOG"
: > "$MOUNT_MARKER"
exit 0
SH
  cat > "$BINDIR/mkdir" <<'SH'
#!/bin/sh
exit 0
SH
  # The single Windows interop call is stubbed here. It must log to $WSL_LOG —
  # NEVER to $CALL_LOG, because existing cases assert `assert_log_lacks 'mount'`.
  # WSL_EXIT / WSL_OUT drive its exit code and output; WSL_MAKE_DEVICE makes the
  # device show up (used to simulate a successful attach).
  cat > "$BINDIR/wsl.exe" <<'SH'
#!/bin/sh
echo "wsl.exe $*" >> "$WSL_LOG"
if [ -n "${WSL_MAKE_DEVICE:-}" ]; then
  : > "$WSL_MAKE_DEVICE"
fi
if [ -n "${WSL_OUT:-}" ]; then
  printf '%s\n' "$WSL_OUT"
fi
exit "${WSL_EXIT:-0}"
SH
  # dockerd is recorded, never started for real: the boot suite must stay
  # hermetic even when a future case drives main() end to end.
  cat > "$BINDIR/dockerd" <<'SH'
#!/bin/sh
echo "dockerd $0 $*" >> "$CALL_LOG"
exit 0
SH
  # `timeout` must strip its own options before exec'ing the interop stub;
  # TIMEOUT_EXIT=124 simulates the hard-timeout verdict.
  cat > "$BINDIR/timeout" <<'SH'
#!/bin/sh
if [ "${TIMEOUT_EXIT:-0}" = "124" ]; then
  exit 124
fi
if [ "${1:-}" = "-k" ]; then
  shift 2
fi
if [ "${1:-}" = "-s" ]; then
  shift 2
fi
shift
exec "$@"
SH
  chmod +x "$BINDIR"/*
}

# gated_blkid: the device exists only once $DEVICE_FLAG appears, so a case can
# start with "not attached" and let the interop stub materialise it.
gated_blkid() {
  cat > "$BINDIR/blkid" <<'SH'
#!/bin/sh
[ -e "$DEVICE_FLAG" ] || exit 1
echo /dev/fakedev
exit 0
SH
  chmod +x "$BINDIR/blkid"
}

# fail_blkid: replace the blkid shim with one that never resolves a device.
fail_blkid() {
  cat > "$BINDIR/blkid" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$BINDIR/blkid"
}

# label_blkid: honours the three blkid call shapes boot uses. BLKID_UUID_DEV is
# the device the UUID lookup finds (empty = UUID unknown, i.e. a disk copied from
# the other variant); BLKID_LABEL_DEVS is the newline-separated list the shared
# LABEL lookup finds (two lines = ambiguity).
label_blkid() {
  cat > "$BINDIR/blkid" <<'SH'
#!/bin/sh
echo "blkid $*" >> "$CALL_LOG"
case "$*" in
  *"UUID="*)
    if [ -n "${BLKID_UUID_DEVS:-}" ]; then
      printf '%s\n' "$BLKID_UUID_DEVS"
      exit 0
    fi
    if [ -n "${BLKID_UUID_DEV:-}" ]; then
      echo "$BLKID_UUID_DEV"
      exit 0
    fi
    exit 1 ;;
  *"LABEL="*)
    if [ -n "${BLKID_LABEL_DEVS:-}" ]; then
      printf '%s\n' "$BLKID_LABEL_DEVS"
      exit 0
    fi
    exit 1 ;;
esac
echo /dev/fakedev
exit 0
SH
  chmod +x "$BINDIR/blkid"
}

# failing_mount: a mount that records its argv but fails (and does NOT mount).
failing_mount() {
  cat > "$BINDIR/mount" <<'SH'
#!/bin/sh
echo "mount $*" >> "$CALL_LOG"
exit 1
SH
  chmod +x "$BINDIR/mount"
}

# conf_with_vhdx: a temp conf declaring the VHDX + UUID, as the installer writes it.
conf_with_vhdx() {
  printf 'DATA_VHDX="%s"\nDATA_UUID="test-uuid-1234"\n' "$VHDX" > "$AGENT_DEVBOX_CONF"
}

# conf_with_mntname <name>: a temp conf declaring only DATA_MNTNAME.
conf_with_mntname() {
  printf "DATA_MNTNAME='%s'\n" "$1" > "$AGENT_DEVBOX_CONF"
}

# conf_with_label <label>: a temp conf declaring the VHDX + UUID (as the
# installer writes them) plus the per-channel data-disk ext4 label.
conf_with_label() {
  printf 'DATA_VHDX="%s"\nDATA_UUID="test-uuid-1234"\nDATA_LABEL="%s"\n' "$VHDX" "$1" > "$AGENT_DEVBOX_CONF"
}

# assert_log_has <substr>: the mount/blkid shims recorded this substring.
assert_log_has() {
  run grep -Fq -- "$1" "$CALL_LOG"
  [ "$status" -eq 0 ]
}

# assert_log_lacks <substr>: no shim ever recorded this substring.
assert_log_lacks() {
  run grep -Fq -- "$1" "$CALL_LOG"
  [ "$status" -ne 0 ]
}

# bind_shims <src-ino> <dst-ino>: mountpoint/mount/stat shims for bind_and_verify.
# "mount" creates $BOUND, mountpoint reports it, and stat answers with the given
# device:inode for the src/dst paths (equal = a real bind, unequal = wrong source).
bind_shims() {
  cat > "$BINDIR/mountpoint" <<'SH'
#!/bin/sh
[ -e "$BOUND" ] && exit 0
exit 1
SH
  cat > "$BINDIR/mount" <<'SH'
#!/bin/sh
: > "$BOUND"
exit 0
SH
  cat > "$BINDIR/stat" <<SH
#!/bin/sh
if [ "\$1" = "-c" ] && [ "\$2" = "%s" ]; then
  /usr/bin/stat -c %s "\$3"
  exit 0
fi
case "\$3" in
  *src*) echo "$1" ;;
  *dst*) echo "$2" ;;
  *) echo "9:9" ;;
esac
SH
  chmod +x "$BINDIR"/mountpoint "$BINDIR"/mount "$BINDIR"/stat
}

# readiness_shims: fake Supervisor/dockerd locks under AGENT_DEVBOX_PROC_FS, a
# real unix socket, probe shims and an advanceable clock. publish_service runs
# from the clock, so the setsid parent has already returned when the pidfile
# appears — the suite never trusts $! or a synchronous child.
readiness_shims() {
  base_shims
  cat > "$BINDIR/mk_proc" <<'SH'
#!/bin/sh
procdir="$1"; pid="$2"; uid="$3"; comm="$4"; title="$5"; start="$6"; exe="$7"; shift 7
p="$procdir/$pid"
/bin/mkdir -p "$p"
zeros=''
i=0
while [ "$i" -lt 18 ]; do zeros="$zeros 0"; i=$((i + 1)); done
printf '%s (%s) S%s %s\n' "$pid" "$comm" "$zeros" "$start" > "$p/stat"
printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$comm" "$uid" "$uid" "$uid" "$uid" > "$p/status"
printf '%s\n' "$comm" > "$p/comm"
{ printf '%s\0' "$title"; for a in "$@"; do printf '%s\0' "$a"; done; } > "$p/cmdline"
ln -sfn "$exe" "$p/exe"
SH
  cat > "$BINDIR/publish_service" <<'SH'
#!/bin/sh
if [ -f "$LAUNCHED_PASEO" ] && [ ! -f "$PASEO_PIDFILE" ]; then
  "$BINDIR/mk_proc" "$AGENT_DEVBOX_PROC_FS" "${PASEO_FAKE_PID:-4242}" \
    "${PASEO_FAKE_UID:-$AGENT_DEVBOX_PASEO_UID}" "Paseo Superviso" "Paseo Supervisor" \
    "${PASEO_FAKE_START:-111}" "$AGENT_DEVBOX_NODE_BIN"
  printf '{"pid":%s,"startedAt":"2026-01-01T00:00:00.000Z","hostname":"h","uid":%s,"listen":"0.0.0.0:6767","heartbeat":true,"bootId":"%s","serverId":"srv_x"}' \
    "${PASEO_FAKE_PID:-4242}" "${PASEO_FAKE_UID:-$AGENT_DEVBOX_PASEO_UID}" \
    "$AGENT_DEVBOX_BOOT_ID" > "$PASEO_PIDFILE"
fi
if [ -f "$LAUNCHED_DOCKERD" ] && [ ! -f "$DOCKERD_PIDFILE" ]; then
  "$BINDIR/mk_proc" "$AGENT_DEVBOX_PROC_FS" "${DOCKERD_FAKE_PID:-5151}" \
    "${DOCKERD_FAKE_UID:-0}" "dockerd" "dockerd" "${DOCKERD_FAKE_START:-222}" \
    "$AGENT_DEVBOX_DOCKERD_BIN" "--pidfile" "$DOCKERD_PIDFILE"
  printf '%s\n' "${DOCKERD_FAKE_PID:-5151}" > "$DOCKERD_PIDFILE"
  python3 - "$AGENT_DEVBOX_DOCKER_SOCK" <<'PY'
import socket
import sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
PY
fi
SH
  cat > "$BINDIR/curl" <<'SH'
#!/bin/sh
echo "curl $*" >> "$CALL_LOG"
if [ -n "${CURL_HOOK:-}" ] && [ -x "$CURL_HOOK" ]; then "$CURL_HOOK" "$@"; fi
printf '%s' "${CURL_CODE:-200}"
exit "${CURL_RC:-0}"
SH
  cat > "$BINDIR/docker" <<'SH'
#!/bin/sh
echo "docker $*" >> "$CALL_LOG"
exit "${DOCKER_INFO_RC:-0}"
SH
  cat > "$BINDIR/setsid" <<'SH'
#!/bin/sh
echo "setsid $*" >> "$CALL_LOG"
case "$*" in
  *dockerd*) : > "$LAUNCHED_DOCKERD" ;;
  *paseo-boot*) : > "$LAUNCHED_PASEO" ;;
esac
if [ -f "$PASEO_PIDFILE" ]; then
  echo "paseo-pidfile-present-at-launch" >> "$CALL_LOG"
fi
exit "${SETSID_EXIT:-0}"
SH
  cat > "$BINDIR/clock" <<'SH'
#!/bin/sh
n=0
if [ -f "$CLOCK_COUNT" ]; then n=$(cat "$CLOCK_COUNT"); fi
n=$((n + 1))
echo "$n" > "$CLOCK_COUNT"
if [ -x "$BINDIR/publish_service" ]; then
  "$BINDIR/publish_service" "$n" >/dev/null 2>&1 || true
fi
echo $((n * 2000))
SH
  printf '#!/bin/sh\nexit 0\n' > "$AGENT_DEVBOX_PASEO_BOOT_BIN"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/node-bin"
  chmod +x "$BINDIR"/* "$AGENT_DEVBOX_PASEO_BOOT_BIN" "$TMP/node-bin"
}

# prep_main: mounted data disk with the first-run marker, successful bind shims,
# an empty conf (no UUID check) and the advanceable clock.
prep_main() {
  readiness_shims
  bind_shims "1:1" "1:1"
  : > "$AGENT_DEVBOX_CONF"
  : > "$MOUNT_MARKER"
  : > "$AGENT_DEVBOX_DATADIR/.initialized"
  : > "$BOUND"
  export AGENT_DEVBOX_NOW_MS_CMD="$BINDIR/clock"
}

# publish_dockerd: pre-create a valid engine lock + socket (already running).
publish_dockerd() {
  "$BINDIR/mk_proc" "$AGENT_DEVBOX_PROC_FS" "${DOCKERD_FAKE_PID:-5151}" 0 \
    "dockerd" "dockerd" "${DOCKERD_FAKE_START:-222}" "$AGENT_DEVBOX_DOCKERD_BIN" \
    "--pidfile" "$DOCKERD_PIDFILE"
  printf '%s\n' "${DOCKERD_FAKE_PID:-5151}" > "$DOCKERD_PIDFILE"
  python3 - "$AGENT_DEVBOX_DOCKER_SOCK" <<'PY'
import socket
import sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
PY
}

# publish_paseo: pre-create a valid Supervisor lock for pid 4242.
publish_paseo() {
  "$BINDIR/mk_proc" "$AGENT_DEVBOX_PROC_FS" "${PASEO_FAKE_PID:-4242}" \
    "${PASEO_FAKE_UID:-$AGENT_DEVBOX_PASEO_UID}" "Paseo Superviso" "Paseo Supervisor" \
    "${PASEO_FAKE_START:-111}" "$AGENT_DEVBOX_NODE_BIN"
  printf '{"pid":%s,"startedAt":"2026-01-01T00:00:00.000Z","hostname":"h","uid":%s,"listen":"0.0.0.0:6767","heartbeat":true,"bootId":"%s","serverId":"srv_x"}' \
    "${PASEO_FAKE_PID:-4242}" "${PASEO_FAKE_UID:-$AGENT_DEVBOX_PASEO_UID}" \
    "$AGENT_DEVBOX_BOOT_ID" > "$PASEO_PIDFILE"
}

@test "sourcing is silent and defines ensure_mounted" {
  run bash -c '. "$SCRIPT"; if declare -f ensure_mounted >/dev/null 2>&1; then echo SOURCED_OK; fi'
  [ "$status" -eq 0 ]
  [ "$output" = "SOURCED_OK" ]
}

@test "already mounted: rc 0 and no mount/blkid call" {
  : > "$MOUNT_MARKER"
  base_shims
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  assert_log_lacks 'mount'
  assert_log_lacks 'blkid'
}

@test "empty DATA_VHDX: rc 1 and no mount call" {
  base_shims
  : > "$AGENT_DEVBOX_CONF"
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  assert_log_lacks 'mount'
}

# 首次 --import 完、安装器还没写 /etc/agent-devbox.conf 时会跑一次 [boot]。这不是故障：
# 日志必须是 INFO（不能吓人的 FATAL），也不能去碰 mount。
@test "missing conf (fresh import): INFO, not FATAL, and no mount call" {
  base_shims
  rm -f "$AGENT_DEVBOX_CONF"
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  # 先存下来：assert_log_* 内部的 run 会覆盖 $output。
  boot_out="$output"
  assert_log_lacks 'mount'
  printf '%s' "$boot_out" | grep -Fq '尚未写入'
  ! printf '%s' "$boot_out" | grep -Fq 'FATAL'
}

# paseo 自己会轮转 daemon.log（10MB x 3），但 /var/log/paseo-boot.log 是本脚本的
# stdout 重定向，没人管 -> 启动前按大小滚一份（保留 .1）。
@test "rotate_log: a small log is left untouched" {
  printf 'hello\n' > "$TMP/paseo.log"
  run bash -c '. "$SCRIPT"; rotate_log "$1" 100' _ "$TMP/paseo.log"
  [ "$status" -eq 0 ]
  [ -s "$TMP/paseo.log" ]
  [ ! -e "$TMP/paseo.log.1" ]
}

@test "rotate_log: an oversized log becomes .1 and a second rotation replaces it" {
  head -c 64 /dev/zero | tr '\0' 'x' > "$TMP/paseo.log"
  run bash -c '. "$SCRIPT"; rotate_log "$1" 10' _ "$TMP/paseo.log"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/paseo.log" ]
  [ -s "$TMP/paseo.log.1" ]
  head -c 64 /dev/zero | tr '\0' 'y' > "$TMP/paseo.log"
  run bash -c '. "$SCRIPT"; rotate_log "$1" 10' _ "$TMP/paseo.log"
  [ "$status" -eq 0 ]
  grep -Fq 'y' "$TMP/paseo.log.1"
  ! grep -Fq 'x' "$TMP/paseo.log.1"
}

@test "main: an oversized paseo log is rotated when the service actually starts" {
  prep_main
  export AGENT_DEVBOX_PASEO_LOG_MAX=10
  head -c 64 /dev/zero | tr '\0' 'x' > "$AGENT_DEVBOX_PASEO_LOG"
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot complete'
  [ -s "$AGENT_DEVBOX_PASEO_LOG.1" ]
}

@test "main: a live Supervisor lock is probed without rotating its log" {
  prep_main
  export AGENT_DEVBOX_PASEO_LOG_MAX=10
  publish_paseo
  head -c 64 /dev/zero | tr '\0' 'x' > "$AGENT_DEVBOX_PASEO_LOG"
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot complete'
  [ ! -e "$AGENT_DEVBOX_PASEO_LOG.1" ]
  assert_log_lacks 'setsid'
}

@test "empty conf (exists but no DATA_VHDX): still reports an unconfigured disk" {
  base_shims
  : > "$AGENT_DEVBOX_CONF"
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -Fq '未配置 DATA_VHDX'
  ! printf '%s' "$output" | grep -Fq '尚未写入'
}

@test "UUID resolvable: rc 0 and mount -t ext4 onto the derived target" {
  base_shims
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  assert_log_has 'mount -t ext4 /dev/fakedev'
  assert_log_has "$AGENT_DEVBOX_DATADIR"
}

@test "blkid never resolves the UUID: rc 1 and no mount call" {
  base_shims
  fail_blkid
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  assert_log_lacks 'mount'
}

@test "mount fails: rc 1 (fail closed)" {
  base_shims
  failing_mount
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# guest-side attach (plan §3.1 / §6): a missing device triggers exactly ONE
# interop call; the single wait_device() decides, not wsl.exe's exit code.
# ---------------------------------------------------------------------------

@test "device already present: no interop call and attach_source=preexisting" {
  base_shims
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  boot_out="$output"
  assert_log_has 'mount -t ext4 /dev/fakedev'
  [ ! -s "$WSL_LOG" ]
  printf '%s' "$boot_out" | grep -Fq 'attach_source=preexisting'
}

@test "boot attach: device appears after the attach -> mount is called" {
  base_shims
  gated_blkid
  conf_with_vhdx
  export WSL_MAKE_DEVICE="$DEVICE_FLAG"
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  boot_out="$output"
  grep -Fq -- '--mount --vhd' "$WSL_LOG"
  grep -Fq -- '--bare' "$WSL_LOG"
  assert_log_has 'mount -t ext4 /dev/fakedev'
  printf '%s' "$boot_out" | grep -Fq 'attach_source=boot'
}

@test "boot attach: rc 255 ALREADY_ATTACHED with the device present is a success" {
  base_shims
  gated_blkid
  conf_with_vhdx
  export WSL_EXIT=255 WSL_OUT='WSL_E_USER_VHD_ALREADY_ATTACHED 0x80040312'
  export WSL_MAKE_DEVICE="$DEVICE_FLAG"
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  boot_out="$output"
  assert_log_has 'mount -t ext4 /dev/fakedev'
  printf '%s' "$boot_out" | grep -Fq 'rc=255'
  printf '%s' "$boot_out" | grep -Fq 'attach_source=preexisting'
}

@test "boot attach fails and no device appears: rc 1 with boot failed" {
  base_shims
  gated_blkid
  conf_with_vhdx
  export WSL_EXIT=255 WSL_OUT='some interop error'
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  boot_out="$output"
  assert_log_lacks 'mount'
  printf '%s' "$boot_out" | grep -Fq 'boot failed: maintenance mode'
}

@test "boot attach timeout (rc 124) is logged and still fails closed" {
  base_shims
  gated_blkid
  conf_with_vhdx
  export TIMEOUT_EXIT=124
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -Fq 'boot attach 超时'
  printf '%s' "$output" | grep -Fq 'boot failed: maintenance mode'
}

@test "AGENT_DEVBOX_BOOT_ATTACH=0: the interop stub is never called" {
  base_shims
  gated_blkid
  conf_with_vhdx
  export AGENT_DEVBOX_BOOT_ATTACH=0 WSL_MAKE_DEVICE="$DEVICE_FLAG"
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  [ ! -s "$WSL_LOG" ]
  printf '%s' "$output" | grep -Fq 'boot attach 已禁用'
}

# ---------------------------------------------------------------------------
# shared label (agents <-> core interchange): a data.vhdx copied into the other
# variant's install dir keeps its source UUID, so the conf UUID never matches.
# Resolution is UUID first, then LABEL=devbox-data; two matches fail closed.
# ---------------------------------------------------------------------------

@test "UUID mismatch falls back to the shared label and mounts that device" {
  base_shims
  label_blkid
  conf_with_vhdx
  export BLKID_LABEL_DEVS='/dev/copieddisk'
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  boot_out="$output"
  assert_log_has 'mount -t ext4 /dev/copieddisk'
  printf '%s' "$boot_out" | grep -Fq 'source=label'
  # A present device needs no attach at all.
  [ ! -s "$WSL_LOG" ]
}

@test "two devices with the same UUID/label fail closed" {
  base_shims
  label_blkid
  conf_with_vhdx
  export BLKID_LABEL_DEVS="$(printf '%s\n%s' /dev/orig /dev/copy)"
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  printf '%s' "$output" > "$TMP/ambiguity.boot.log"
  assert_log_lacks 'mount'
  grep -Fq '多块' "$TMP/ambiguity.boot.log"
  grep -Fq 'boot failed: maintenance mode' "$TMP/ambiguity.boot.log"
  run grep -Fq 'boot complete' "$TMP/ambiguity.boot.log"
  [ "$status" -ne 0 ]
  # The banner must explain the two-device case (MOTD_HINT).
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted; write_maintenance_motd'
  [ "$status" -eq 0 ]
  run grep -Fq '多块' "$AGENT_DEVBOX_MOTD"
  [ "$status" -eq 0 ]
}

@test "two attached copies sharing the SAME UUID fail closed (no coin flip)" {
  base_shims
  label_blkid
  conf_with_vhdx
  export BLKID_UUID_DEVS="$(printf '%s\n%s' /dev/orig /dev/copy)"
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  printf '%s' "$output" > "$TMP/same-uuid.boot.log"
  assert_log_lacks 'mount'
  grep -Fq '多块' "$TMP/same-uuid.boot.log"
  grep -Fq 'boot failed: maintenance mode' "$TMP/same-uuid.boot.log"
}

# ---------------------------------------------------------------------------
# per-channel data-disk label: stable uses `devbox-data`, beta uses
# `devbox-data-beta` (16 chars, the ext4 limit). Precedence is
# AGENT_DEVBOX_DATA_LABEL > conf DATA_LABEL > devbox-data, and the env override
# must survive load_conf()'s reset-then-source of the installer-written conf.
# ---------------------------------------------------------------------------

@test "conf DATA_LABEL drives the label lookup (beta channel)" {
  base_shims
  label_blkid
  conf_with_label 'devbox-data-beta'
  unset AGENT_DEVBOX_DATA_LABEL
  export BLKID_LABEL_DEVS='/dev/betadisk'
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  assert_log_has 'LABEL=devbox-data-beta'
  assert_log_has 'mount -t ext4 /dev/betadisk'
}

@test "AGENT_DEVBOX_DATA_LABEL beats the conf label" {
  base_shims
  label_blkid
  conf_with_label 'devbox-data-beta'
  export AGENT_DEVBOX_DATA_LABEL='devbox-data-env' BLKID_LABEL_DEVS='/dev/envdisk'
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  assert_log_has 'LABEL=devbox-data-env'
  assert_log_lacks 'LABEL=devbox-data-beta'
  assert_log_has 'mount -t ext4 /dev/envdisk'
}

@test "env-only beta label works with a stable conf" {
  base_shims
  label_blkid
  conf_with_label 'devbox-data'
  export AGENT_DEVBOX_DATA_LABEL='devbox-data-beta' BLKID_LABEL_DEVS='/dev/betadisk'
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  assert_log_has 'LABEL=devbox-data-beta'
  run grep -Fxq 'blkid -o device -t LABEL=devbox-data' "$CALL_LOG"
  [ "$status" -ne 0 ]
  assert_log_has 'mount -t ext4 /dev/betadisk'
}

@test "legacy conf without DATA_LABEL still uses the stable label" {
  base_shims
  label_blkid
  conf_with_vhdx
  unset AGENT_DEVBOX_DATA_LABEL
  export BLKID_LABEL_DEVS='/dev/stabledisk'
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  run grep -Fxq 'blkid -o device -t LABEL=devbox-data' "$CALL_LOG"
  [ "$status" -eq 0 ]
  assert_log_has 'mount -t ext4 /dev/stabledisk'
}

@test "static guard: load_conf re-applies the env label after sourcing the conf" {
  # The env value is snapshotted at source time (before load_conf may reset
  # DATA_LABEL), then re-applied AFTER the conf is sourced. Order matters: if the
  # re-apply ran first, sourcing a conf with DATA_LABEL would silently win.
  run grep -Fq 'DATA_LABEL_ENV="${AGENT_DEVBOX_DATA_LABEL:-}"' "$SCRIPT"
  [ "$status" -eq 0 ]
  run awk '
    /^load_conf\(\)/ { infn = 1 }
    infn { body = body $0 "\n"; if ($0 == "}") exit }
    END {
      n = split(body, L, "\n")
      reset = source = apply = 0
      for (i = 1; i <= n; i++) {
        if (L[i] ~ /DATA_LABEL="devbox-data"/ && !reset) reset = i
        if (L[i] ~ /^[[:space:]]*\. "[$]CONF"$/ && !source) source = i
        if (index(L[i], "DATA_LABEL=\"${DATA_LABEL_ENV:-${DATA_LABEL:-devbox-data}}\"") && !apply) apply = i
      }
      if (reset && source && apply && reset < source && source < apply) print "ORDER_OK"
      else print "ORDER_BAD reset=" reset " source=" source " apply=" apply
    }
  ' "$SCRIPT"
  [ "$output" = "ORDER_OK" ]
}

@test "write_maintenance_motd gives both copy-paste repair commands" {
  printf 'DATA_VHDX="D:\\WSL\\agent-devbox\\data.vhdx"\nDATA_DISTRO="Ubuntu-26.04"\n' > "$AGENT_DEVBOX_CONF"
  run bash -c '. "$SCRIPT"; load_conf; write_maintenance_motd'
  [ "$status" -eq 0 ]
  # 在 WSL 终端里直接粘贴（不需要切到 Windows PowerShell）。
  grep -Fq 'cmd.exe /c "D:\WSL\agent-devbox\mount-datadisk.cmd"' "$AGENT_DEVBOX_MOTD"
  grep -Fq 'wsl.exe --terminate Ubuntu-26.04' "$AGENT_DEVBOX_MOTD"
  # 互操作不可用时的 PowerShell 兜底（带编号，和上面两条区分开）。
  grep -Fq '1) D:\WSL\agent-devbox\mount-datadisk.cmd' "$AGENT_DEVBOX_MOTD"
  grep -Fq '2) wsl --terminate Ubuntu-26.04' "$AGENT_DEVBOX_MOTD"
}

@test "DATADIR derives from DATA_MNTNAME when AGENT_DEVBOX_DATADIR is unset" {
  conf_with_mntname 'devbox-data'
  run env -u AGENT_DEVBOX_DATADIR bash -c '. "$SCRIPT"; load_conf; echo "$DATADIR"'
  [ "$status" -eq 0 ]
  [ "$output" = "/mnt/devbox-data" ]

  conf_with_mntname 'custom'
  run env -u AGENT_DEVBOX_DATADIR bash -c '. "$SCRIPT"; load_conf; echo "$DATADIR"'
  [ "$status" -eq 0 ]
  [ "$output" = "/mnt/custom" ]
}

@test "write_maintenance_motd points at the install.ps1 web entry" {
  run bash -c '. "$SCRIPT"; write_maintenance_motd'
  [ "$status" -eq 0 ]
  [ -s "$AGENT_DEVBOX_MOTD" ]
  run grep -Fq 'install.ps1' "$AGENT_DEVBOX_MOTD"
  [ "$status" -eq 0 ]
  run grep -Fq 'raw.githubusercontent.com' "$AGENT_DEVBOX_MOTD"
  [ "$status" -eq 0 ]
}

@test "clear_motd truncates the MOTD to empty" {
  printf 'stale maintenance banner\n' > "$AGENT_DEVBOX_MOTD"
  run bash -c '. "$SCRIPT"; clear_motd'
  [ "$status" -eq 0 ]
  [ -f "$AGENT_DEVBOX_MOTD" ]
  [ ! -s "$AGENT_DEVBOX_MOTD" ]
}

@test "bind_and_verify: rc 0 when the target shares the source device:inode" {
  export BOUND="$TMP/bound"
  bind_shims "1:1" "1:1"
  run bash -c '. "$SCRIPT"; bind_and_verify "$TMP/src" "$TMP/dst"'
  [ "$status" -eq 0 ]
  [ -e "$BOUND" ]
}

@test "bind_and_verify: rc 1 when the target is not the source (fail closed)" {
  export BOUND="$TMP/bound"
  : > "$BOUND"
  bind_shims "1:1" "2:2"
  run bash -c '. "$SCRIPT"; bind_and_verify "$TMP/src" "$TMP/dst"'
  [ "$status" -eq 1 ]
}

@test "static guard: one bare-attach interop call, no re-entrant tokens" {
  # The ONLY Windows binary in the boot LOGIC must be the single bare attach, and
  # that same line must carry --mount --vhd --bare. Anything else re-enters
  # Windows from [boot] (the historical boot-loop cause). write_maintenance_motd()
  # is the ONE place allowed to name `wsl.exe --terminate` (the user pastes it
  # into this WSL terminal), so its body is stripped out first and checked on its
  # own.
  stripped="$TMP/stripped.sh"
  motd_fn="$TMP/motd-fn.sh"
  awk -v motdfn="$motd_fn" '
    /^write_maintenance_motd\(\)/ { infn = 1 }
    infn { print > motdfn; if ($0 == "}") infn = 0; next }
    { print }
  ' "$SCRIPT" > "$stripped"
  [ -s "$motd_fn" ]

  run grep -c 'wsl\.exe' "$stripped"
  [ "$output" -eq 1 ]
  run grep 'wsl\.exe' "$stripped"
  printf '%s' "$output" | grep -Fq -- '--mount'
  printf '%s' "$output" | grep -Fq -- '--vhd'
  printf '%s' "$output" | grep -Fq -- '--bare'
  run grep -Eq 'schtasks' "$stripped"
  [ "$status" -ne 0 ]
  run grep -Eq 'wsl -d' "$stripped"
  [ "$status" -ne 0 ]
  run grep -Eq -- '--unmount' "$stripped"
  [ "$status" -ne 0 ]
  run grep -Eq -- '--shutdown' "$stripped"
  [ "$status" -ne 0 ]
  run grep -Fq '/mnt/wsl' "$stripped"
  [ "$status" -ne 0 ]
  run grep -Fq 'install-agent-devbox' "$stripped"
  [ "$status" -ne 0 ]

  # The MOTD body must hand the user commands they can PASTE into WSL (no
  # PowerShell detour), and must not smuggle a re-entrant call of its own.
  run grep -Fq 'cmd.exe /c' "$motd_fn"
  [ "$status" -eq 0 ]
  run grep -Fq 'wsl.exe --terminate' "$motd_fn"
  [ "$status" -eq 0 ]
  run grep -Eq 'schtasks' "$motd_fn"
  [ "$status" -ne 0 ]
  run grep -Eq 'wsl -d' "$motd_fn"
  [ "$status" -ne 0 ]
  run grep -Eq -- '--unmount' "$motd_fn"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# start_dockerd(): fire-and-forget engine start. It must be a no-op when the
# binary is absent, must not spawn a second engine over a live pidfile, and must
# sit between the home shim and paseo in main().
# ---------------------------------------------------------------------------

@test "start_dockerd: an absent binary is a fatal missing-binary, not a no-op" {
  base_shims
  export AGENT_DEVBOX_DOCKERD_BIN=
  run bash -c '. "$SCRIPT"; start_dockerd; echo "rc=$? reason=${READY_REASON:-}"'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'rc=2 reason=missing-binary'
  [ ! -e "$AGENT_DEVBOX_DOCKERD_PID" ]
  assert_log_lacks 'setsid'
}

@test "start_dockerd: a live PID with the wrong identity fails and is never killed" {
  base_shims
  export AGENT_DEVBOX_PROC_FS=/proc
  tail -f /dev/null >/dev/null 2>&1 &
  live=$!
  echo "$live" > "$AGENT_DEVBOX_DOCKERD_PID"
  run bash -c '. "$SCRIPT"; start_dockerd; echo "rc=$? reason=${READY_REASON:-}"'
  status_saved=$status
  kill -0 "$live"
  alive=$?
  kill "$live" 2>/dev/null || true
  [ "$status_saved" -eq 0 ]
  [ "$alive" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'rc=2 reason=identity'
  assert_log_lacks 'setsid'
}

@test "start_dockerd: a correctly identified live engine is only probed" {
  prep_main
  publish_dockerd
  run bash -c '. "$SCRIPT"; start_dockerd; echo "rc=$? reason=${READY_REASON:-}"'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'rc=0'
  printf '%s' "$output" | grep -Fq '只探测不重启'
  assert_log_lacks 'setsid'
}

@test "start_dockerd: execs the resolved absolute path with the exact --pidfile" {
  prep_main
  run bash -c '. "$SCRIPT"; start_dockerd; echo "rc=$? reason=${READY_REASON:-}"'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'rc=0'
  run grep -F -- "setsid --fork $BINDIR/dockerd --pidfile $AGENT_DEVBOX_DOCKERD_PID" "$CALL_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- '--wait' "$CALL_LOG"
  [ "$status" -ne 0 ]
}

@test "wsl-boot exports PATH for child execs" {
  # The real [boot] environment has NO PATH. Without the top-level export,
  # `command -v dockerd` still succeeds (bash's built-in default) but the
  # `setsid` child inherits no PATH and dies with ENOENT.
  run bash -c 'unset PATH; . "$SCRIPT"; printf "%s" "$PATH"'
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" ]
}

@test "verify_data_uuid: a device stacked twice is not a mismatch" {
  base_shims
  cat > "$BINDIR/findmnt" <<'SH'
#!/bin/sh
printf '%s\n%s\n' '11111111-1111-1111-1111-111111111111' '11111111-1111-1111-1111-111111111111'
SH
  chmod +x "$BINDIR/findmnt"
  run bash -c '. "$SCRIPT"; DATA_UUID=11111111-1111-1111-1111-111111111111; DATADIR=/mnt/x; verify_data_uuid'
  [ "$status" -eq 0 ]
  ! printf '%s' "$output" | grep -Fq 'UUID mismatch'
}

@test "verify_data_uuid: two different UUIDs fail closed" {
  base_shims
  cat > "$BINDIR/findmnt" <<'SH'
#!/bin/sh
printf '%s\n%s\n' '11111111-1111-1111-1111-111111111111' '22222222-2222-2222-2222-222222222222'
SH
  chmod +x "$BINDIR/findmnt"
  run bash -c '. "$SCRIPT"; DATA_UUID=11111111-1111-1111-1111-111111111111; DATADIR=/mnt/x; verify_data_uuid'
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -Fq 'UUID mismatch'
  printf '%s' "$output" | grep -Fq 'boot failed: maintenance mode'
}

@test "main: a UUID mismatch writes the maintenance banner and exits 0" {
  base_shims
  # Device present, mount marker set, but the UUID read from the mounted disk differs.
  : > "$DEVICE_FLAG"
  : > "$MOUNT_MARKER"
  cat > "$AGENT_DEVBOX_CONF" <<'SH'
DATA_UUID='11111111-1111-1111-1111-111111111111'
DATA_MNTNAME='devbox-data'
SH
  cat > "$BINDIR/findmnt" <<'SH'
#!/bin/sh
case " $* " in
  *" UUID "*) printf '%s\n' '22222222-2222-2222-2222-222222222222'; exit 0 ;;
esac
if [ -e "$MOUNT_MARKER" ]; then exit 0; fi
exit 1
SH
  chmod +x "$BINDIR/findmnt"
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'UUID mismatch'
  printf '%s' "$output" | grep -Fq 'boot failed: maintenance mode'
  ! printf '%s' "$output" | grep -Fq 'boot complete'
  ! printf '%s' "$output" | grep -Fq '启动 paseo 服务'
  grep -Fq 'mount-datadisk.cmd' "$AGENT_DEVBOX_MOTD"
}

@test "main: the call trace launches dockerd before paseo" {
  prep_main
  : > "$AGENT_DEVBOX_OVERLAY_MARKER"
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  docker_line=$(grep -n "setsid --fork $BINDIR/dockerd" "$CALL_LOG" | cut -d: -f1)
  paseo_line=$(grep -n "setsid --fork $AGENT_DEVBOX_PASEO_BOOT_BIN" "$CALL_LOG" | cut -d: -f1)
  [ -n "$docker_line" ] && [ -n "$paseo_line" ]
  [ "$docker_line" -lt "$paseo_line" ]
}

# ---------------------------------------------------------------------------
# ensure_opencode_shim(): the OpenCode DESKTOP app resolves the CLI inside a WSL
# distro ONLY at "$HOME/.opencode/bin/opencode" (no PATH lookup) and then runs
# "<that path> serve --hostname ... --port ...". The image ships the CLI at
# /usr/local/bin/opencode, so this shim must exist in every home we boot with.
# These cases deliberately do NOT call base_shims()/bind_shims(): that would
# install the harness's no-op `mkdir` and fake `stat` shims and break the real
# file operations under test.
# ---------------------------------------------------------------------------

# fake_cli <path>: a stand-in for /usr/local/bin/opencode (prints its version).
fake_cli() {
  printf '#!/bin/sh\necho 1.19.3\n' > "$1"
  chmod +x "$1"
}

# shim <home>...: source the boot script with a temp CLI and run the shim.
shim() {
  env AGENT_DEVBOX_OPENCODE_BIN="$TMP/pkg/opencode" \
    bash -c '. "$SCRIPT"; ensure_opencode_shim "$@"' _ "$@"
}

@test "ensure_opencode_shim: creates \$HOME/.opencode/bin/opencode -> CLI" {
  mkdir -p "$TMP/pkg" "$TMP/h1"
  fake_cli "$TMP/pkg/opencode"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [ -L "$TMP/h1/.opencode/bin/opencode" ]
  [ "$(readlink "$TMP/h1/.opencode/bin/opencode")" = "$TMP/pkg/opencode" ]
  run "$TMP/h1/.opencode/bin/opencode"
  [ "$output" = "1.19.3" ]
}

@test "ensure_opencode_shim: second run is a no-op (same link, rc 0)" {
  mkdir -p "$TMP/pkg" "$TMP/h1"
  fake_cli "$TMP/pkg/opencode"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  before="$(readlink "$TMP/h1/.opencode/bin/opencode")"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [ "$(readlink "$TMP/h1/.opencode/bin/opencode")" = "$before" ]
}

@test "ensure_opencode_shim: keeps a desktop-installed real CLI untouched" {
  mkdir -p "$TMP/pkg" "$TMP/h1/.opencode/bin"
  fake_cli "$TMP/pkg/opencode"
  printf '#!/bin/sh\necho DESKTOP\n' > "$TMP/h1/.opencode/bin/opencode"
  chmod +x "$TMP/h1/.opencode/bin/opencode"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [ ! -L "$TMP/h1/.opencode/bin/opencode" ]
  run "$TMP/h1/.opencode/bin/opencode"
  [ "$output" = "DESKTOP" ]
}

@test "ensure_opencode_shim: chmod +x an existing but non-executable CLI" {
  mkdir -p "$TMP/pkg" "$TMP/h1/.opencode/bin"
  fake_cli "$TMP/pkg/opencode"
  printf '#!/bin/sh\necho KEPT\n' > "$TMP/h1/.opencode/bin/opencode"
  chmod -x "$TMP/h1/.opencode/bin/opencode"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [ ! -L "$TMP/h1/.opencode/bin/opencode" ]
  [ -x "$TMP/h1/.opencode/bin/opencode" ]
  run "$TMP/h1/.opencode/bin/opencode"
  [ "$output" = "KEPT" ]
}

@test "ensure_opencode_shim: replaces a dangling symlink" {
  mkdir -p "$TMP/pkg" "$TMP/h1/.opencode/bin"
  fake_cli "$TMP/pkg/opencode"
  ln -s "$TMP/gone/opencode" "$TMP/h1/.opencode/bin/opencode"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [ -L "$TMP/h1/.opencode/bin/opencode" ]
  [ "$(readlink "$TMP/h1/.opencode/bin/opencode")" = "$TMP/pkg/opencode" ]
}

@test "ensure_opencode_shim: never deletes a directory at the target path" {
  mkdir -p "$TMP/pkg" "$TMP/h1/.opencode/bin/opencode"
  fake_cli "$TMP/pkg/opencode"
  : > "$TMP/h1/.opencode/bin/opencode/keep"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [ -d "$TMP/h1/.opencode/bin/opencode" ]
  [ -f "$TMP/h1/.opencode/bin/opencode/keep" ]
}

@test "ensure_opencode_shim: no CLI shipped -> rc 0 and nothing created" {
  mkdir -p "$TMP/h1"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/h1/.opencode" ]
}

@test "ensure_opencode_shim: ignores a home that does not exist" {
  mkdir -p "$TMP/pkg"
  fake_cli "$TMP/pkg/opencode"
  run shim "$TMP/nope"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/nope" ]
}

@test "ensure_opencode_shim: patches every given home (root + paseo)" {
  mkdir -p "$TMP/pkg" "$TMP/root" "$TMP/home-paseo"
  fake_cli "$TMP/pkg/opencode"
  run shim "$TMP/root" "$TMP/home-paseo"
  [ "$status" -eq 0 ]
  [ "$(readlink "$TMP/root/.opencode/bin/opencode")" = "$TMP/pkg/opencode" ]
  [ "$(readlink "$TMP/home-paseo/.opencode/bin/opencode")" = "$TMP/pkg/opencode" ]
}

@test "ensure_opencode_shim: logs an already-ready symlink with its target" {
  mkdir -p "$TMP/pkg" "$TMP/h1"
  fake_cli "$TMP/pkg/opencode"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [ -L "$TMP/h1/.opencode/bin/opencode" ]
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"已就绪"* ]]
  [[ "$output" == *"$TMP/h1/.opencode/bin/opencode"* ]]
  [[ "$output" == *"$TMP/pkg/opencode"* ]]
}

@test "ensure_opencode_shim: logs an existing executable wrapper as unchanged" {
  mkdir -p "$TMP/pkg" "$TMP/h1/.opencode/bin"
  fake_cli "$TMP/pkg/opencode"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$TMP/pkg/opencode" > "$TMP/h1/.opencode/bin/opencode"
  chmod +x "$TMP/h1/.opencode/bin/opencode"
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"保持不变"* ]]
  [ ! -L "$TMP/h1/.opencode/bin/opencode" ]
  run head -n 1 "$TMP/h1/.opencode/bin/opencode"
  [ "$output" = '#!/bin/sh' ]
  run "$TMP/h1/.opencode/bin/opencode"
  [ "$status" -eq 0 ]
  [ "$output" = "1.19.3" ]
}

@test "ensure_opencode_shim: logs a chmod repair" {
  mkdir -p "$TMP/pkg" "$TMP/h1/.opencode/bin"
  fake_cli "$TMP/pkg/opencode"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$TMP/pkg/opencode" > "$TMP/h1/.opencode/bin/opencode"
  chmod -x "$TMP/h1/.opencode/bin/opencode"
  [ ! -x "$TMP/h1/.opencode/bin/opencode" ]
  run shim "$TMP/h1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"补充可执行位"* ]]
  [ -x "$TMP/h1/.opencode/bin/opencode" ]
}
# ---------------------------------------------------------------------------
# readiness handshake (P0-1): one 30s monotonic deadline shared by every
# required service, Supervisor/dockerd identity from /proc, the overlay marker
# deciding whether dockerd is required, and exactly ONE `boot complete`.
# ---------------------------------------------------------------------------

@test "main: without the overlay marker docker is never launched or probed" {
  prep_main
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot complete'
  assert_log_lacks 'docker '
  assert_log_lacks 'dockerd'
}

@test "main: overlay marker, both services ready -> exactly one boot complete" {
  prep_main
  : > "$AGENT_DEVBOX_OVERLAY_MARKER"
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  boot_out="$output"
  [ "$(printf '%s\n' "$boot_out" | grep -cF 'boot complete')" -eq 1 ]
  grep -Fq 'docker ' "$CALL_LOG"
  grep -Fq 'curl ' "$CALL_LOG"
  grep -F -- "setsid --fork $BINDIR/dockerd --pidfile $AGENT_DEVBOX_DOCKERD_PID" "$CALL_LOG"
  grep -F -- "setsid --fork $AGENT_DEVBOX_PASEO_BOOT_BIN" "$CALL_LOG"
  # The parent returned before the lock appeared: this is not $!.
  run grep -Fq 'paseo-pidfile-present-at-launch' "$CALL_LOG"
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$boot_out" | tail -n 1 | grep -cF 'boot complete')" -eq 1 ]
}

@test "main: overlay marker without dockerd fails closed and never starts paseo" {
  prep_main
  : > "$AGENT_DEVBOX_OVERLAY_MARKER"
  export AGENT_DEVBOX_DOCKERD_BIN=
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot failed: service=dockerd reason=missing-binary'
  grep -Fq 'readiness failed: service=dockerd reason=missing-binary' "$AGENT_DEVBOX_DOCKERD_LOG"
  ! printf '%s' "$output" | grep -Fq 'boot complete'
  assert_log_lacks 'setsid'
  grep -Fq '数据盘已挂载；dockerd 未就绪。 Data disk mounted; dockerd not ready.' "$AGENT_DEVBOX_MOTD"
  run grep -Fq 'mount-datadisk.cmd' "$AGENT_DEVBOX_MOTD"
  [ "$status" -ne 0 ]
}

@test "main: a Supervisor lock with the wrong uid fails even when HTTP is 200" {
  prep_main
  export PASEO_FAKE_UID=9999
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot failed: service=paseo reason=identity'
  ! printf '%s' "$output" | grep -Fq 'boot complete'
  assert_log_lacks 'curl '
  grep -Fq 'readiness failed: service=paseo reason=identity' "$AGENT_DEVBOX_PASEO_LOG"
  grep -Fq '数据盘已挂载；paseo 未就绪。 Data disk mounted; paseo not ready.' "$AGENT_DEVBOX_MOTD"
  run grep -Fq 'mount-datadisk.cmd' "$AGENT_DEVBOX_MOTD"
  [ "$status" -ne 0 ]
}

@test "main: the same PID with a changed starttime fails as identity" {
  prep_main
  cat > "$TMP/mutate-start" <<SH
#!/bin/sh
"$BINDIR/mk_proc" "$AGENT_DEVBOX_PROC_FS" "\${PASEO_FAKE_PID:-4242}" \\
  "\$AGENT_DEVBOX_PASEO_UID" "Paseo Superviso" "Paseo Supervisor" 999 "\$AGENT_DEVBOX_NODE_BIN"
SH
  chmod +x "$TMP/mutate-start"
  export CURL_HOOK="$TMP/mutate-start"
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot failed: service=paseo reason=identity'
  ! printf '%s' "$output" | grep -Fq 'boot complete'
}

@test "main: an unopenable paseo log prevents that launch" {
  prep_main
  /bin/mkdir -p "$TMP/paseo-log-dir"
  export AGENT_DEVBOX_PASEO_LOG="$TMP/paseo-log-dir"
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot failed: service=paseo reason=log-open'
  ! printf '%s' "$output" | grep -Fq 'boot complete'
  assert_log_lacks 'setsid'
}

@test "main: an unopenable dockerd log prevents that launch" {
  prep_main
  : > "$AGENT_DEVBOX_OVERLAY_MARKER"
  /bin/mkdir -p "$TMP/dockerd-log-dir"
  export AGENT_DEVBOX_DOCKERD_LOG="$TMP/dockerd-log-dir"
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot failed: service=dockerd reason=log-open'
  ! printf '%s' "$output" | grep -Fq 'boot complete'
  assert_log_lacks 'setsid'
}

@test "main: a 503 health probe times out the shared 30s (service=paseo)" {
  prep_main
  export CURL_CODE=503
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot failed: service=paseo reason=timeout'
  ! printf '%s' "$output" | grep -Fq 'boot complete'
  grep -Fq 'readiness failed: service=paseo reason=timeout' "$AGENT_DEVBOX_PASEO_LOG"
  grep -Fq '数据盘已挂载；paseo 未就绪。 Data disk mounted; paseo not ready.' "$AGENT_DEVBOX_MOTD"
}

@test "main: an unready dockerd times out the SAME deadline (service=dockerd)" {
  prep_main
  : > "$AGENT_DEVBOX_OVERLAY_MARKER"
  export DOCKER_INFO_RC=1
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'boot failed: service=dockerd reason=timeout'
  ! printf '%s' "$output" | grep -Fq 'boot complete'
  grep -Fq 'curl ' "$CALL_LOG"
  grep -Fq 'readiness failed: service=dockerd reason=timeout' "$AGENT_DEVBOX_DOCKERD_LOG"
  grep -Fq '数据盘已挂载；dockerd 未就绪。 Data disk mounted; dockerd not ready.' "$AGENT_DEVBOX_MOTD"
  run grep -Fq 'mount-datadisk.cmd' "$AGENT_DEVBOX_MOTD"
  [ "$status" -ne 0 ]
}

@test "main: two consecutive runs never double-start a service" {
  prep_main
  : > "$AGENT_DEVBOX_OVERLAY_MARKER"
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  run bash -c '. "$SCRIPT"; main'
  [ "$status" -eq 0 ]
  [ "$(grep -cF "setsid --fork $AGENT_DEVBOX_PASEO_BOOT_BIN" "$CALL_LOG")" -eq 1 ]
  [ "$(grep -cF "setsid --fork $BINDIR/dockerd" "$CALL_LOG")" -eq 1 ]
}

@test "static guard: readiness never uses a background operator, --wait or the shell PID" {
  run grep -nE 'setsid[^#]*&[[:space:]]*$' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -nE '\$!' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -Fq -- '--wait' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -nE 'comm=node|comm=[^ ]*node' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -nE 'daemon run' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -Fq '/run/agent-devbox-paseo.pid' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -Fq 'grep paseo' "$SCRIPT"
  [ "$status" -ne 0 ]
}
