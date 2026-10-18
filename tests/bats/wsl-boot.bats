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

@test "write_maintenance_motd names both launchers in the MOTD" {
  run bash -c '. "$SCRIPT"; write_maintenance_motd'
  [ "$status" -eq 0 ]
  [ -s "$AGENT_DEVBOX_MOTD" ]
  run grep -Fq 'agent-devbox.bat' "$AGENT_DEVBOX_MOTD"
  [ "$status" -eq 0 ]
  run grep -Fq 'agent-devbox-core.bat' "$AGENT_DEVBOX_MOTD"
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
