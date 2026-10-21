#!/usr/bin/env bats
# wsl-boot.sh: pins the data-disk mount chain in ensure_mounted().
#
# The script is safe to source (BASH_SOURCE guard) and reads its paths from
# AGENT_DEVBOX_* env vars AT SOURCE TIME, so every case runs in an isolated
# subshell against a temp conf/log/datadir plus a fake bin dir prepended to PATH.
# findmnt/sleep/blkid/mount/wsl.exe/schtasks.exe are all shimmed; a shim "succeeds"
# by creating the mounted-marker, so no real Windows tools are required.
#
# SCRIPT is overridable via WSL_BOOT_SH so this same suite can be pointed at an old
# revision (git show HEAD:scripts/wsl-boot.sh) to prove it can actually fail.

setup() {
  export TMP="$(mktemp -d)"
  export SCRIPT="${WSL_BOOT_SH:-$BATS_TEST_DIRNAME/../../scripts/wsl-boot.sh}"
  export BINDIR="$TMP/bin"
  export MOUNT_MARKER="$TMP/mounted.marker"
  export CALL_LOG="$TMP/calls.log"
  export VHDX="$TMP/data.vhdx"
  export AGENT_DEVBOX_CONF="$TMP/agent-devbox.conf"
  export AGENT_DEVBOX_LOG="$TMP/boot.log"
  export AGENT_DEVBOX_DATADIR="$TMP/data"
  export AGENT_DEVBOX_MNTNAME="agent-devbox-data"
  export AGENT_DEVBOX_TASK="agent-devbox-mount-datadisk"
  mkdir -p "$BINDIR" "$AGENT_DEVBOX_DATADIR"
  : > "$CALL_LOG"
  : > "$AGENT_DEVBOX_LOG"
  export PATH="$BINDIR:$PATH"
}

teardown() { rm -rf "$TMP"; }

# base_shims: findmnt reports "mounted" iff the marker exists; sleep is instant;
# blkid resolves the UUID to a fake device; mount records its argv and mounts.
base_shims() {
  cat > "$BINDIR/findmnt" <<'SH'
#!/bin/sh
[ -e "$MOUNT_MARKER" ] && exit 0
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
  chmod +x "$BINDIR"/*
}

# tool_shim <exe> [touch]: write an executable that appends its argv to CALL_LOG;
# when touch=1 it also creates the mounted-marker (simulating a successful mount).
tool_shim() {
  local exe="$1" touch="${2:-0}"
  {
    printf '#!/bin/sh\n'
    printf 'echo "%s $*" >> "$CALL_LOG"\n' "$exe"
    [ "$touch" = "1" ] && printf ': > "$MOUNT_MARKER"\n' || printf ':\n'
    printf 'exit 0\n'
  } > "$BINDIR/$exe"
  chmod +x "$BINDIR/$exe"
}

# conf_with_vhdx: a temp conf declaring the VHDX + UUID, as the installer writes it.
conf_with_vhdx() {
  printf 'DATA_VHDX="%s"\nDATA_UUID="test-uuid-1234"\n' "$VHDX" > "$AGENT_DEVBOX_CONF"
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

@test "already mounted: rc 0, no wsl.exe/schtasks.exe call" {
  : > "$MOUNT_MARKER"
  base_shims
  tool_shim schtasks.exe 0
  tool_shim wsl.exe 0
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  run grep -Fq 'schtasks.exe' "$CALL_LOG"; [ "$status" -ne 0 ]
  run grep -Fq 'wsl.exe' "$CALL_LOG"; [ "$status" -ne 0 ]
}

@test "empty DATA_VHDX: rc 1 before any attach attempt" {
  base_shims
  : > "$AGENT_DEVBOX_CONF"
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  run grep -Fq 'wsl.exe' "$CALL_LOG"; [ "$status" -ne 0 ]
  run grep -Fq 'schtasks.exe' "$CALL_LOG"; [ "$status" -ne 0 ]
}

@test "scheduled task succeeds: rc 0 and schtasks.exe /run /tn invoked" {
  base_shims
  tool_shim schtasks.exe 1
  tool_shim wsl.exe 0
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  grep -Fq 'schtasks.exe /run /tn agent-devbox-mount-datadisk' "$CALL_LOG"
  # The task mounted the disk, so the direct wsl.exe step must be skipped.
  run grep -Fq 'wsl.exe' "$CALL_LOG"; [ "$status" -ne 0 ]
}

@test "direct mount succeeds: rc 0, wsl.exe --type ext4 --name invoked" {
  base_shims
  tool_shim wsl.exe 1
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  grep -Fq -- '--type ext4' "$CALL_LOG"
  grep -Fq -- '--name agent-devbox-data' "$CALL_LOG"
  run grep -Fq -- '--bare' "$CALL_LOG"; [ "$status" -ne 0 ]
}

@test "only the --bare fallback succeeds: rc 0 via blkid + manual mount" {
  base_shims
  tool_shim wsl.exe 0
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 0 ]
  grep -Fq -- '--bare' "$CALL_LOG"
  grep -Fq 'mount -t ext4 /dev/fakedev' "$CALL_LOG"
}

@test "all strategies fail: rc 1" {
  base_shims
  cat > "$BINDIR/blkid" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$BINDIR/blkid"
  tool_shim schtasks.exe 0
  tool_shim wsl.exe 0
  conf_with_vhdx
  run bash -c '. "$SCRIPT"; load_conf; ensure_mounted'
  [ "$status" -eq 1 ]
  grep -Fq 'schtasks.exe' "$CALL_LOG"
  grep -Fq 'wsl.exe' "$CALL_LOG"
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

@test "static guard: no reference to the Windows installer" {
  run grep -q 'install-agent-devbox' "$SCRIPT"
  [ "$status" -ne 0 ]
}
