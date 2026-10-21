#!/usr/bin/env bash
# =============================================================================
# wsl-boot.sh — WSL2 boot script, run as root from /etc/wsl.conf [boot] command.
#
# Responsibilities (idempotent):
#   1. Ensure the VHDX data disk is attached and mounted at /mnt/wsl/<name>.
#   2. VERIFY the disk identity (mountpoint + optional UUID) — fail closed.
#   3. First-run: seed /home, /root, /workspace onto the data disk.
#   4. Bind /home, /root and /workspace onto the data disk.
#   5. Start the paseo daemon as `paseo` (single owner, backgrounded).
#
# It NEVER formats a disk. Formatting happens only in datadisk-init.sh, which is
# invoked by the Windows installer for a freshly created VHDX. It also NEVER
# re-launches the Windows installer: if the data disk cannot be mounted it enters
# MAINTENANCE MODE and tells the user to run agent-devbox.bat themselves.
#
# SHELL OPTIONS — deliberately `set -uo pipefail` with NO `-e`:
#   The mount chain has several best-effort steps that are EXPECTED to fail (the
#   elevated Scheduled Task may not exist, `wsl.exe --mount --type ext4` can fail
#   on some WSL builds, `--bare` needs a follow-up manual mount). Under `set -e`
#   any one of those failures would abort the script BEFORE we could log it or
#   write the MAINTENANCE MOTD. So we intentionally omit `-e` and check every
#   step's exit status explicitly. Errors are still loud: they are logged and
#   either advanced past or turned into a fail-closed exit 0 (MAINTENANCE MODE).
#
# Layout: credentials/identity come from /etc/agent-devbox.conf (written by the
# Windows installer): DATA_VHDX, DATA_UUID, PASEO_PASSWORD, DATA_MNTNAME,
# DATA_TASK. The installer also registers an elevated Scheduled Task (named by
# DATA_TASK) that runs `wsl.exe --mount --vhd <path> --type ext4 --name ...`.
#
# This file is safe to SOURCE — every side effect lives in a function, and the
# entry point is guarded by the BASH_SOURCE check at the bottom.
# =============================================================================
set -uo pipefail

# --- env-overridable constants (overridable so tests can point them at tmp) ---
CONF="${AGENT_DEVBOX_CONF:-/etc/agent-devbox.conf}"
DATADIR="${AGENT_DEVBOX_DATADIR:-/mnt/wsl/agent-devbox-data}"
MNTNAME="${AGENT_DEVBOX_MNTNAME:-agent-devbox-data}"
TASKNAME="${AGENT_DEVBOX_TASK:-agent-devbox-mount-datadisk}"
LOG_FILE="${AGENT_DEVBOX_LOG:-/var/log/agent-devbox-boot.log}"

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
# then let DATA_MNTNAME / DATA_TASK override the mount name / task name, and
# export PASEO_PASSWORD for the daemon child.
load_conf() {
  DATA_VHDX=""
  DATA_UUID=""
  PASEO_PASSWORD=""
  # shellcheck source=/dev/null
  if [ -f "$CONF" ]; then
    . "$CONF"
  fi
  if [ -n "${DATA_MNTNAME:-}" ]; then
    MNTNAME="$DATA_MNTNAME"
  fi
  if [ -n "${DATA_TASK:-}" ]; then
    TASKNAME="$DATA_TASK"
  fi
  export PASEO_PASSWORD
}

# wsl_exe(): locate wsl.exe on PATH, else the fixed System32 path.
wsl_exe() {
  if command -v wsl.exe >/dev/null 2>&1; then
    command -v wsl.exe
  elif [ -x /mnt/c/Windows/System32/wsl.exe ]; then
    echo /mnt/c/Windows/System32/wsl.exe
  fi
}

# schtasks_exe(): locate schtasks.exe on PATH, else the fixed System32 path.
schtasks_exe() {
  if command -v schtasks.exe >/dev/null 2>&1; then
    command -v schtasks.exe
  elif [ -x /mnt/c/Windows/System32/schtasks.exe ]; then
    echo /mnt/c/Windows/System32/schtasks.exe
  fi
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
  src="$(stat -c '%d:%i' "$1" 2>/dev/null || true)"
  dst="$(stat -c '%d:%i' "$2" 2>/dev/null || true)"
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

# ensure_mounted(): the 5-step mount chain. Every step is best-effort and
# non-fatal; returns 0 the moment $DATADIR is mounted, else 1.
ensure_mounted() {
  local wx st dev

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

  wx="$(wsl_exe)"
  st="$(schtasks_exe)"
  log "正在挂载数据盘… (vhd=$DATA_VHDX)"

  # 3) preferred: trigger the elevated Scheduled Task registered by the installer.
  if [ -n "$st" ]; then
    log "调用计划任务 $TASKNAME 挂载数据盘"
    "$st" /run /tn "$TASKNAME" || log "计划任务 $TASKNAME 运行失败（继续尝试直接挂载）"
    wait_mounted 30 && return 0
  fi

  # 4) direct: wsl.exe --mount with an explicit --type ext4 (auto-detection of a
  #    whole-disk ext4 image fails on some WSL builds).
  if [ -n "$wx" ]; then
    log "直接调用 wsl.exe --mount --type ext4"
    "$wx" --mount --vhd "$DATA_VHDX" --type ext4 --name "$MNTNAME" || log "wsl.exe --mount --type ext4 失败（继续回退）"
    wait_mounted 30 && return 0
  fi

  # 5) fallback: --bare attach, then find the device by UUID and mount it manually.
  log "回退挂载：--bare 附加数据盘，再按 UUID 手动挂载"
  if [ -n "$wx" ]; then
    "$wx" --mount --vhd "$DATA_VHDX" --bare || log "wsl.exe --mount --bare 失败（继续按 UUID 探测）"
  fi
  dev=""
  for _ in $(seq 1 30); do
    dev="$(dev_by_uuid)" && break
    sleep 1
  done
  if [ -n "$dev" ]; then
    mkdir -p "$DATADIR"
    mount -t ext4 "$dev" "$DATADIR" || log "手动挂载 $dev 到 $DATADIR 失败"
    wait_mounted 10 && return 0
  fi

  # 6) every strategy failed.
  return 1
}

# main(): the full boot sequence.
main() {
  local cur
  load_conf

  if ! ensure_mounted; then
    log "FATAL: data disk not mounted at $DATADIR（数据盘未挂载）"
    cat >/etc/motd <<'EOF'
*** agent-devbox is in MAINTENANCE MODE / 维护模式 ***
数据盘未挂载，未初始化也未启动服务。
The data disk is not mounted, so nothing was seeded or started.
请运行 Windows 安装器 agent-devbox.bat 创建/挂载数据盘。
Run the Windows installer (agent-devbox.bat) to create/attach the data disk.
EOF
    exit 0
  fi
  log "数据盘挂载成功"

  # --- verify identity; fail closed on UUID mismatch -------------------------
  if [ -n "${DATA_UUID:-}" ]; then
    cur="$(findmnt -rno UUID --mountpoint "$DATADIR" 2>/dev/null || true)"
    if [ "$cur" != "$DATA_UUID" ]; then
      log "FATAL: data disk UUID mismatch (found='$cur' expected='$DATA_UUID')（数据盘 UUID 不匹配）"
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
