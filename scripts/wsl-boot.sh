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
MOTD_FILE="${AGENT_DEVBOX_MOTD:-/etc/motd}"
# OPENCODE_BIN is the CLI this image ships (npm global). The OpenCode DESKTOP app
# does NOT search PATH when it looks for a CLI inside a WSL distro: it only runs
# `[ -x "$HOME/.opencode/bin/opencode" ]` and then execs that exact path (see
# ensure_opencode_shim). Overridable so the bats suite can point at a fake CLI.
OPENCODE_BIN="${AGENT_DEVBOX_OPENCODE_BIN:-/usr/local/bin/opencode}"
# DATADIR is derived in load_conf() from DATA_MNTNAME / AGENT_DEVBOX_DATADIR.
# Left empty at source time (unless explicitly overridden) so sourcing has no
# side effects and no hardcoded path leaks in.
DATADIR="${AGENT_DEVBOX_DATADIR:-}"
# Our own boot-time paseo stdout log. NOT daemon.log: paseo rotates that file itself
# (10MB x 3, see @getpaseo/server/dist/scripts/supervisor-log-config.js). This one is
# written by the `>>` redirect in main(), so nothing else can bound it.
PASEO_LOG="${AGENT_DEVBOX_PASEO_LOG:-/var/log/paseo-boot.log}"
PASEO_LOG_MAX="${AGENT_DEVBOX_PASEO_LOG_MAX:-5242880}"

# Installer-populated values (reloaded by load_conf). Pre-declared empty so the
# functions stay safe under `set -u` even when called directly, or when the file
# is sourced without main()/load_conf() first.
DATA_VHDX=""
DATA_UUID=""
PASEO_PASSWORD=""
# 1 = 配置还没写（`wsl --import` 刚完成、安装器随后才写并重启）。首次启动不是故障，
# 日志里不能打成 FATAL，否则每次新装都像出错（见 main()）。
CONF_MISSING=0

# --- functions ---------------------------------------------------------------

# log(): print to stdout only. /etc/wsl.conf redirects the whole boot command
# into /var/log/agent-devbox-boot.log (`>>`), so writing the file here too would
# duplicate every line.
log() {
  local msg
  msg="[wsl-boot $(date -Is)] $*"
  # stdout only: /etc/wsl.conf redirects the boot command into the log file.
  echo "$msg"
}

# load_conf(): reset the installer-written values, source the config if present,
# then resolve the mount name and the concrete DATADIR, and export
# PASEO_PASSWORD for the daemon child.
load_conf() {
  DATA_VHDX=""
  DATA_UUID=""
  PASEO_PASSWORD=""
  CONF_MISSING=0
  # shellcheck source=/dev/null
  if [ -f "$CONF" ]; then
    . "$CONF"
  else
    CONF_MISSING=1
  fi
  MNTNAME="${DATA_MNTNAME:-devbox-data}"
  if [ -n "${AGENT_DEVBOX_DATADIR:-}" ]; then
    DATADIR="$AGENT_DEVBOX_DATADIR"
  else
    DATADIR="/mnt/$MNTNAME"
  fi
  export PASEO_PASSWORD
}

# rotate_log(): keep an append-redirected log bounded: once $1 exceeds $2 bytes,
# move it to "$1.1" (one previous generation) so the next redirect starts fresh.
# Safe here: the child that owns the redirect has not started yet, and this
# script's own output goes to a DIFFERENT file (/etc/wsl.conf redirects it).
rotate_log() {
  local f="$1" max="$2" size
  [ -f "$f" ] || return 0
  size="$(stat -c %s "$f" 2>/dev/null)" || size=0
  [ "${size:-0}" -gt "$max" ] || return 0
  if mv -f "$f" "$f.1" 2>/dev/null; then
    log "已轮转 $f（${size} 字节 > ${max} 字节）：上一份保留为 $f.1"
  else
    : > "$f"
    log "已清空 $f（${size} 字节 > ${max} 字节；改名失败）"
  fi
  return 0
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

# ensure_opencode_shim(): expose the shipped CLI at the ONLY path the OpenCode
# DESKTOP app probes inside a WSL distro -- it never consults PATH:
#   sh -lc 'if [ -x "$HOME/.opencode/bin/opencode" ]; then printf "%s\n" ...'
# then execs that path as `opencode serve --hostname ... --port ...`. Without
# this, a distro whose /root lives on the persistent data disk reports
# "OpenCode is not installed" even though `opencode` is on PATH.
# Idempotent and best-effort: an existing executable (including a real CLI the
# desktop app installed itself) is never touched, a dangling link is replaced,
# and nothing here may abort the boot. Args: the home directories to patch.
ensure_opencode_shim() {
  local home target owner
  if [ ! -x "$OPENCODE_BIN" ]; then
    log "警告：未找到可执行的 OpenCode CLI（$OPENCODE_BIN），跳过桌面版探测链接"
    return 0
  fi
  for home in "$@"; do
    [ -d "$home" ] || continue
    target="$home/.opencode/bin/opencode"
    if [ -f "$target" ] && [ -x "$target" ]; then
      if [ -L "$target" ]; then
        log "桌面版 OpenCode 探测路径已就绪：$target -> $(readlink "$target" 2>/dev/null)"
      else
        log "桌面版 OpenCode 探测路径已就绪（已有可执行文件，保持不变）：$target"
      fi
      continue
    fi
    if [ -d "$target" ] && [ ! -L "$target" ]; then
      log "警告：$target 是目录，跳过（如非用户自建请手动删除）"
      continue
    fi
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      if chmod +x "$target" 2>/dev/null && [ -x "$target" ]; then
        log "已为 $target 补充可执行位"
      else
        log "警告：无法修复 $target 的可执行位"
      fi
      continue
    fi
    if ! mkdir -p "$home/.opencode/bin" 2>/dev/null; then
      log "警告：无法创建 $home/.opencode/bin"
      continue
    fi
    if ! ln -sfn "$OPENCODE_BIN" "$target" 2>/dev/null; then
      log "警告：无法创建 $target"
      continue
    fi
    owner="$(stat -c '%u:%g' "$home" 2>/dev/null)"
    if [ -n "$owner" ]; then
      chown "$owner" "$home/.opencode" "$home/.opencode/bin" 2>/dev/null || true
      chown -h "$owner" "$target" 2>/dev/null || true
    fi
    log "已创建桌面版 OpenCode 探测链接：$target -> $OPENCODE_BIN"
  done
  return 0
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
    if [ "$CONF_MISSING" -eq 1 ]; then
      log "$CONF 尚未写入（首次导入，等待安装器写入并重启）"
    else
      log "未配置 DATA_VHDX，无法挂载数据盘"
    fi
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
请重新运行 Windows 安装脚本（PowerShell）来创建/挂载数据盘：
Re-run the Windows installer (in PowerShell) to create/attach the data disk:
  irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
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
    if [ "$CONF_MISSING" -eq 1 ]; then
      # 首次导入：安装器还没写 $CONF。不是故障；维护 MOTD 仍然写（万一安装失败，
      # 用户进来看得到“重跑安装器”的指引），但日志级别是 INFO。
      log "首次启动：$CONF 尚未写入（安装器随后写入并重启），本次跳过挂载与服务启动"
    else
      log "FATAL: data disk not mounted at $DATADIR（数据盘未挂载）"
    fi
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

  # --- desktop-app CLI visibility (must run AFTER the binds: /root and /home/*
  # live on the data disk, so an image-side link alone cannot repair an upgrade) -
  ensure_opencode_shim /root /home/*

  # --- start the daemon as paseo (single owner) ------------------------------
  if [ -f /run/agent-devbox-paseo.pid ] && kill -0 "$(cat /run/agent-devbox-paseo.pid)" 2>/dev/null; then
    log "paseo 服务已在运行"
  else
    log "启动 paseo 服务 …"
    rotate_log "$PASEO_LOG" "$PASEO_LOG_MAX"
    setsid /usr/local/bin/paseo-boot.sh >>"$PASEO_LOG" 2>&1 &
    echo $! > /run/agent-devbox-paseo.pid
  fi

  log "boot complete"
}

# --- entry point (guarded so the file can be sourced without side effects) ----
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
