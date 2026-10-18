#!/usr/bin/env bash
# =============================================================================
# wsl-boot.sh — WSL2 boot script, run as root from /etc/wsl.conf [boot] command.
#
# Design (PURE-LINUX mount; NO Windows interop):
#   Attaching the VHDX is the Windows side's job: a logon Scheduled Task runs a
#   hidden PowerShell that attaches the VHDX as a BARE block device (`wsl
#   --mount --vhd <path> --bare`) on the host. By the time this script runs, the
#   guest already sees the raw disk. This script then does everything in Linux:
#     1. Find the already-attached block device by UUID (blkid -U).
#     2. `mount -t ext4 <dev> /mnt/<mntname>` (mntname from DATA_MNTNAME,
#        default `devbox-data`, read out of /etc/agent-devbox.conf).
#     3. VERIFY the mount identity (mountpoint + UUID) — fail closed.
#     4. First-run: seed /home, /root, /workspace onto the data disk.
#     5. Bind /home, /root and /workspace onto the data disk.
#     6. Start the paseo daemon as `paseo` (single owner, backgrounded).
#
# WHY NO INTEROP HERE (root cause of a confirmed boot loop):
#   This file runs from `[boot]` on EVERY distro start — a point where WSL interop
#   is not yet ready. Shelling out to Windows tooling (a bare attach, or triggering
#   the host task) from inside `[boot]` is re-entrant and unsupported: the Windows
#   binary is not on PATH yet, and a bare mount also needs an elevated token. Doing
#   it here made the distro restart after the task trigger, then loop, then shut the
#   VM down. So this script calls NO Windows binary (no wsl / no schtasks): the host
#   attaches, the guest mounts, purely in Linux.
#
# NEVER FORMATS: formatting happens only in datadisk-init.sh, invoked by the Windows
# installer for a freshly created VHDX. It also NEVER re-launches the Windows
# installer: if the data disk cannot be mounted it enters MAINTENANCE MODE and tells
# the user to run the installer themselves.
#
# MOUNT PATH: the data disk lives at /mnt/<name>, NOT under /mnt/ (the auto-mount
# tmpfs shared across distros). A shared, distro-independent location would let two
# distros using the same mount name collide on an identical path. Hence /mnt/<name>.
#
# SHELL OPTIONS — deliberately `set -uo pipefail` with NO `-e`:
#   The device wait is best-effort (the host Scheduled Task may not have attached
#   the disk yet), and every step must be able to log before we bail out. Under
#   `set -e` a single failed command would abort before we could write the
#   MAINTENANCE MOTD. So we check every exit status explicitly instead. Errors stay
#   loud: they are logged and turned into a fail-closed exit 0 (MAINTENANCE MODE).
#
# Layout: credentials/identity come from /etc/agent-devbox.conf (written by the
# Windows installer): DATA_VHDX, DATA_UUID, PASEO_PASSWORD, DATA_MNTNAME (and
# DATA_TASK, consumed by the Windows side).
#
# This file is safe to SOURCE — every side effect lives in a function, and the
# entry point is guarded by the BASH_SOURCE check at the bottom.
# =============================================================================
set -uo pipefail

# --- env-overridable constants (overridable so tests can point them at tmp) ---
CONF="${AGENT_DEVBOX_CONF:-/etc/agent-devbox.conf}"
LOG_FILE="${AGENT_DEVBOX_LOG:-/var/log/agent-devbox-boot.log}"
MOTD_FILE="${AGENT_DEVBOX_MOTD:-/etc/motd}"
# DATADIR is derived in load_conf() from DATA_MNTNAME / AGENT_DEVBOX_DATADIR.
# Left empty at source time (unless explicitly overridden) so sourcing has no
# side effects and no hardcoded path leaks in.
DATADIR="${AGENT_DEVBOX_DATADIR:-}"

# Installer-populated values (reloaded by load_conf). Pre-declared empty so the
# functions stay safe under `set -u` even when called directly, or when the file
# is sourced without main()/load_conf() first.
DATA_VHDX=""
DATA_UUID=""
PASEO_PASSWORD=""

# --- functions ---------------------------------------------------------------

# log(): print to stdout AND append to $LOG_FILE (stdout is already redirected
# into the same file by wsl.conf; the explicit append keeps direct-run logging).
log() {
  local msg
  msg="[wsl-boot $(date -Is)] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# load_conf(): reset the installer-written values, source the config if present,
# then resolve the mount name and the concrete DATADIR, and export
# PASEO_PASSWORD for the daemon child.
load_conf() {
  DATA_VHDX=""
  DATA_UUID=""
  PASEO_PASSWORD=""
  # shellcheck source=/dev/null
  if [ -f "$CONF" ]; then
    . "$CONF"
  fi
  MNTNAME="${DATA_MNTNAME:-devbox-data}"
  if [ -n "${AGENT_DEVBOX_DATADIR:-}" ]; then
    DATADIR="$AGENT_DEVBOX_DATADIR"
  else
    DATADIR="/mnt/$MNTNAME"
  fi
  export PASEO_PASSWORD
}

# is_mounted(): true when $DATADIR is a live mountpoint.
is_mounted() {
  findmnt -rn --mountpoint "$DATADIR" >/dev/null 2>&1
}

# bind_and_verify(): bind $1 onto $2 (idempotent) and confirm $2 really is a bind
# of $1. findmnt is unreliable here: for a bind mount its SOURCE is
# "<device>[/subpath]" and its FSROOT is the path RELATIVE TO THE SOURCE
# filesystem (e.g. "/home", not "$DATADIR/home"). A bind mount does share the
# source directory's device:inode, so compare that instead.
bind_and_verify() {
  mountpoint -q "$2" || mount --bind "$1" "$2"
  local src dst
  src="$(stat -c '%d:%i' "$1" 2>/dev/null)"
  dst="$(stat -c '%d:%i' "$2" 2>/dev/null)"
  if [ -z "$src" ] || [ -z "$dst" ]; then
    return 1
  fi
  [ "$src" = "$dst" ]
}

# dev_by_uuid(): print the device backing $DATA_UUID, or return 1 when it is
# unset or no such filesystem is attached.
dev_by_uuid() {
  [ -n "$DATA_UUID" ] || return 1
  blkid -U "$DATA_UUID"
}

# wait_mounted(N): poll is_mounted for up to N seconds (default 30).
wait_mounted() {
  local n="${1:-30}"
  for _ in $(seq 1 "$n"); do
    if is_mounted; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ensure_mounted(): PURE-LINUX mount chain (no interop). The host has already
# attached the VHDX as a bare block device; here we only wait for the device to
# appear (found by UUID), mount it by hand, and confirm. Returns 0 the moment
# $DATADIR is mounted, else 1. Every step is logged; none is fatal by itself.
ensure_mounted() {
  local dev

  # 1) already mounted -> nothing to do.
  if is_mounted; then
    log "数据盘已挂载于 $DATADIR，跳过挂载"
    return 0
  fi

  # 2) no VHDX configured -> cannot mount.
  if [ -z "$DATA_VHDX" ]; then
    log "未配置 DATA_VHDX，无法挂载数据盘"
    return 1
  fi

  # 3) wait up to 30s for the host-sided attach to expose the block device.
  log "正在按 UUID 查找数据盘… (uuid=$DATA_UUID)"
  dev=""
  for _ in $(seq 1 30); do
    if dev="$(dev_by_uuid)"; then
      if [ -n "$dev" ]; then
        break
      fi
    fi
    sleep 1
  done

  # 4) device never appeared -> the host task likely has not attached yet.
  if [ -z "$dev" ]; then
    log "未找到 UUID=$DATA_UUID 的数据盘设备（宿主计划任务可能尚未附加）"
    return 1
  fi

  # 5) mount the raw device at $DATADIR.
  mkdir -p "$DATADIR"
  if ! mount -t ext4 "$dev" "$DATADIR"; then
    log "挂载 $dev 到 $DATADIR 失败"
    return 1
  fi

  # 6) confirm the mount actually took.
  if is_mounted; then
    return 0
  fi
  return 1
}

# write_maintenance_motd(): fail-closed notice shown to the user on login.
write_maintenance_motd() {
  cat > "$MOTD_FILE" <<'EOF'
*** agent-devbox is in MAINTENANCE MODE / 维护模式 ***
数据盘未挂载，未初始化也未启动服务。
The data disk is not mounted, so nothing was seeded or started.
请运行 Windows 安装器（agent-devbox.bat 或 agent-devbox-core.bat）创建/挂载数据盘。
Run the Windows installer (agent-devbox.bat / agent-devbox-core.bat) to create/attach the data disk.
EOF
}

# clear_motd(): drop any stale maintenance notice on a healthy boot. Best effort;
# it never masks anything else.
clear_motd() {
  : > "$MOTD_FILE"
}

# main(): the full boot sequence.
main() {
  local cur
  load_conf

  if ! ensure_mounted; then
    log "FATAL: data disk not mounted at $DATADIR（数据盘未挂载）"
    write_maintenance_motd
    exit 0
  fi
  log "数据盘挂载成功"
  clear_motd

  # --- verify identity; fail closed on UUID mismatch -------------------------
  if [ -n "${DATA_UUID:-}" ]; then
    cur="$(findmnt -rno UUID --mountpoint "$DATADIR" 2>/dev/null)"
    if [ "$cur" != "$DATA_UUID" ]; then
      log "FATAL: data disk UUID mismatch (found='$cur' expected='$DATA_UUID')（数据盘 UUID 不匹配）"
      write_maintenance_motd
      exit 0
    fi
  fi

  # --- first-run seed (marker-based; only mark after a FULL successful copy) --
  if [ ! -e "$DATADIR/.initialized" ]; then
    log "首次运行：初始化数据盘"
    mkdir -p "$DATADIR/home" "$DATADIR/root" "$DATADIR/workspace"
    seed_ok=1
    tar -C /home --numeric-owner -cf - . 2>/dev/null | tar -C "$DATADIR/home" --numeric-owner -xpf - || seed_ok=0
    tar -C /root --numeric-owner -cf - . 2>/dev/null | tar -C "$DATADIR/root" --numeric-owner -xpf - || seed_ok=0
    if [ "$seed_ok" -eq 1 ]; then
      touch "$DATADIR/.initialized"
    else
      log "警告：数据盘初始化未完成，将在下次启动重试"
    fi
  fi

  # --- bind mounts (verified; fail closed) -----------------------------------
  log "绑定 /home /root /workspace"
  bind_ok=1
  bind_and_verify "$DATADIR/home" /home || bind_ok=0
  bind_and_verify "$DATADIR/root" /root || bind_ok=0
  bind_and_verify "$DATADIR/workspace" /workspace || bind_ok=0
  if [ "$bind_ok" -ne 1 ]; then
    log "FATAL: /home /root /workspace 未正确绑定到数据盘，拒绝启动服务"
    write_maintenance_motd
    exit 0
  fi
  chmod 0700 /root

  # --- start the daemon as paseo (single owner) ------------------------------
  if [ -f /run/agent-devbox-paseo.pid ] && kill -0 "$(cat /run/agent-devbox-paseo.pid)" 2>/dev/null; then
    log "paseo 服务已在运行"
  else
    log "启动 paseo 服务 …"
    setsid /usr/local/bin/paseo-boot.sh >>/var/log/paseo-boot.log 2>&1 &
    echo $! > /run/agent-devbox-paseo.pid
  fi

  log "boot complete"
}

# --- entry point (guarded so the file can be sourced without side effects) ----
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
