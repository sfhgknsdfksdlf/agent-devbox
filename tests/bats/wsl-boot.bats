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
  mkdir -p "$BINDIR" "$AGENT_DEVBOX_DATADIR"
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
echo "dockerd $*" >> "$CALL_LOG"
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
case "\$3" in
  *src*) echo "$1" ;;
  *dst*) echo "$2" ;;
  *) echo "9:9" ;;
esac
SH
  chmod +x "$BINDIR"/mountpoint "$BINDIR"/mount "$BINDIR"/stat
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

@test "main: the paseo stdout log is rotated before the child starts" {
  run grep -nE 'rotate_log "\$PASEO_LOG" "\$PASEO_LOG_MAX"' "$SCRIPT"
  [ "$status" -eq 0 ]
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

@test "start_dockerd: absent dockerd is a logged no-op" {
  base_shims
  export AGENT_DEVBOX_DOCKERD_BIN=
  run bash -c '. "$SCRIPT"; start_dockerd'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Fq 'dockerd 未安装'
  [ ! -e "$AGENT_DEVBOX_DOCKERD_PID" ]
}

@test "start_dockerd: a live pidfile is not restarted" {
  base_shims
  # tail, not sleep: base_shims replaces sleep with an instant-exit shim.
  tail -f /dev/null >/dev/null 2>&1 &
  live=$!
  echo "$live" > "$AGENT_DEVBOX_DOCKERD_PID"
  run bash -c '. "$SCRIPT"; start_dockerd'
  status_saved=$status
  kill "$live" 2>/dev/null || true
  [ "$status_saved" -eq 0 ]
  printf '%s' "$output" | grep -Fq "dockerd 已在运行"
  ! grep -q 'dockerd' "$CALL_LOG"
}

@test "start_dockerd: is called after the home shim and before paseo" {
  shim_idx=$(grep -n 'ensure_opencode_shim /root /home/\*' "$SCRIPT" | cut -d: -f1)
  docker_idx=$(grep -n '^  start_dockerd$' "$SCRIPT" | cut -d: -f1)
  paseo_idx=$(grep -n 'setsid /usr/local/bin/paseo-boot.sh' "$SCRIPT" | cut -d: -f1)
  [ -n "$shim_idx" ] && [ -n "$docker_idx" ] && [ -n "$paseo_idx" ]
  [ "$docker_idx" -gt "$shim_idx" ] && [ "$docker_idx" -lt "$paseo_idx" ]
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
