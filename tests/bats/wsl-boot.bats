#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
# wsl-boot.sh: pins the PURE-LINUX data-disk mount chain in ensure_mounted().
#
# The target interface is deliberately Windows-tool-free: boot no longer shells
# out to wsl.exe / schtasks.exe. It derives the data-disk mountpoint from
# load_conf() (AGENT_DEVBOX_DATADIR > /mnt/$DATA_MNTNAME), resolves the device
# by UUID via `blkid -U`, and mounts it directly with `mount -t ext4`. Failure
# is expressed as a bilingual MAINTENANCE MOTD (naming both launchers), never by
# re-launching the Windows installer.
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
  export CALL_LOG="$TMP/calls.log"
  export VHDX="$TMP/data.vhdx"
  export AGENT_DEVBOX_CONF="$TMP/agent-devbox.conf"
  export AGENT_DEVBOX_LOG="$TMP/boot.log"
  export AGENT_DEVBOX_DATADIR="$TMP/data"
  export AGENT_DEVBOX_MOTD="$TMP/motd"
  mkdir -p "$BINDIR" "$AGENT_DEVBOX_DATADIR"
  : > "$CALL_LOG"
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
  chmod +x "$BINDIR"/*
}

# fail_blkid: replace the blkid shim with one that never resolves a device.
fail_blkid() {
  cat > "$BINDIR/blkid" <<'SH'
#!/bin/sh
exit 1
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

@test "static guard: no Windows-tool or old-installer tokens" {
  run grep -Eq 'wsl\.exe' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -Eq 'schtasks\.exe' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -Eq '/mnt/c/Windows' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -Eq '/mnt/wsl' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -Fq 'install-agent-devbox' "$SCRIPT"
  [ "$status" -ne 0 ]
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
