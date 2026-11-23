#!/usr/bin/env bash
# =============================================================================
# wsl-boot.sh — WSL2 boot script, run as root from /etc/wsl.conf [boot] command.
#
# Design (guest-side attach + pure-Linux mount):
#   The VHDX is attached as a BARE block device by the guest itself, on every
#   start, through the ONE allowed interop call:
#     `wsl --mount --vhd <winpath> --bare`   (see attach_vhdx: hard timeout)
#   This closes the "shutdown mid-session -> permanently in maintenance" hole
#   that existed while only a Windows logon task could attach the disk.
#   Everything after the attach stays in Linux:
#     1. Wait for the attached block device up to DEVICE_WAIT seconds. Only ONE
#        wait per boot. Identity is resolved by UUID first, then by the channel's
#        ext4 label (`devbox-data` stable / `devbox-data-beta` beta), which is
#        what makes same-channel agents and core data disks interchangeable: a
#        copied VHDX keeps the source UUID, so it only resolves by label. Two
#        matches (original + copy both attached) fail closed — boot never picks
#        one.
#     2. `mount -t ext4 <dev> /mnt/<mntname>` (mntname from DATA_MNTNAME,
#        default `devbox-data`, read out of /etc/agent-devbox.conf).
#     3. VERIFY the mount identity (mountpoint + UUID) — fail closed.
#     4. First-run: seed /home, /root, /workspace onto the data disk.
#     5. Bind /home, /root and /workspace onto the data disk.
#     6. Start the paseo daemon as `paseo` (single owner, backgrounded).
#
# WHY EXACTLY ONE INTEROP CALL (root cause of a confirmed boot loop):
#   This file runs from `[boot]` on EVERY distro start, a point where interop is
#   not reliably ready. Re-entering Windows from here (starting another distro,
#   detaching the disk, shutting the VM down) is re-entrant and unsupported: it
#   made the distro restart, then loop, then shut the VM down. So the ONLY Windows
#   binary this script ever runs is the bare attach above, it always carries
#   `timeout -k 2` + ATTACH_TIMEOUT (default 8s, plus 2s kill grace), and its
#   outcome never blocks boot — the single device wait and the mount decide.
#   AGENT_DEVBOX_BOOT_ATTACH=0 is the rollback switch (logs why and goes straight
#   to the wait/maintenance path). This script is the only attach path: nothing
#   outside it (re)attaches the disk.
#
# NEVER FORMATS: formatting happens only in datadisk-init.sh, invoked by the Windows
# installer for a freshly created VHDX. It also NEVER re-launches the Windows
# installer: if the data disk cannot be mounted it enters MAINTENANCE MODE and
# prints repair commands that work *inside this WSL terminal* — paste
# `cmd.exe /c "<InstallDir>\mount-datadisk.cmd"` then `wsl --terminate <distro>`
# and reopen the distro — plus a Windows PowerShell fallback. The same commands
# go to the MOTD and the boot log.
#
# MOUNT PATH: the data disk lives at /mnt/<name>, NOT under /mnt/ (the auto-mount
# tmpfs shared across distros). A shared, distro-independent location would let two
# distros using the same mount name collide on an identical path. Hence /mnt/<name>.
#
# SHELL OPTIONS — deliberately `set -uo pipefail` with NO `-e`:
#   The device wait is best-effort (the in-guest attach may not have brought the
#   disk up yet), and every step must be able to log before we bail out. Under
#   `set -e` a single failed command would abort before we could write the
#   MAINTENANCE MOTD. So we check every exit status explicitly instead. Errors stay
#   loud: they are logged and turned into a fail-closed exit 0 (MAINTENANCE MODE).
#
# Layout: credentials/identity come from /etc/agent-devbox.conf (6 keys written
# by the Windows installer): DATA_VHDX, DATA_UUID, PASEO_PASSWORD, DATA_MNTNAME,
# DATA_DISTRO, DATA_LABEL. Label precedence: AGENT_DEVBOX_DATA_LABEL (env) >
# conf DATA_LABEL > `devbox-data`. Labels are per channel: `devbox-data` (stable)
# / `devbox-data-beta` (beta, exactly 16 chars — the ext4 limit).
#
# This file is safe to SOURCE — every side effect lives in a function, and the
# entry point is guarded by the BASH_SOURCE check at the bottom.
# =============================================================================
set -uo pipefail

# Shared, pure parser (no external dirname: the [boot] env has no PATH yet).
case "${BASH_SOURCE[0]}" in
  */*) _wsl_boot_dir="${BASH_SOURCE[0]%/*}" ;;
  *) _wsl_boot_dir="." ;;
esac
# shellcheck source=scripts/paseo-env.sh
. "$_wsl_boot_dir/paseo-env.sh"

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
# dockerd is only shipped by the WSL rootfs overlay (the OCI image stays lean), so
# every value here is best-effort. `-` (not `:-`) for the BINARY on purpose: an
# explicitly empty value means "absent" (the bats suite uses it), while unset
# means plain `dockerd` from PATH.
DOCKERD_LOG="${AGENT_DEVBOX_DOCKERD_LOG:-/var/log/dockerd.log}"
DOCKERD_LOG_MAX="${AGENT_DEVBOX_DOCKERD_LOG_MAX:-5242880}"
DOCKERD_PID="${AGENT_DEVBOX_DOCKERD_PID:-/run/agent-devbox-dockerd.pid}"
DOCKERD_BIN="${AGENT_DEVBOX_DOCKERD_BIN-dockerd}"
# --- boot readiness handshake (P0-1) ----------------------------------------
# The Supervisor writes this JSON lock itself (owned by paseo); wsl-boot never
# writes it and never trusts the shell's background PID. The old launch-time
# pidfile under /run is gone.
PASEO_PID="${AGENT_DEVBOX_PASEO_PID:-/home/paseo/.paseo/paseo.pid}"
PASEO_USER="${AGENT_DEVBOX_PASEO_USER:-paseo}"
PASEO_BOOT_BIN="${AGENT_DEVBOX_PASEO_BOOT_BIN:-/usr/local/bin/paseo-boot.sh}"
# The readiness probe follows the SAME PASEO_LISTEN paseo-boot parses; an
# explicit override still wins (tests use it). An invalid value keeps the safe
# default here while paseo-boot fails closed on that value.
PASEO_HEALTH_URL="${AGENT_DEVBOX_PASEO_HEALTH_URL:-}"
if [ -z "$PASEO_HEALTH_URL" ]; then
  if paseo_parse_listen "${PASEO_LISTEN:-0.0.0.0:6767}"; then
    PASEO_HEALTH_URL="http://$PASEO_PROBE_HOST:$PASEO_PORT/api/health"
  else
    PASEO_HEALTH_URL="http://127.0.0.1:6767/api/health"
    printf 'WARN: invalid PASEO_LISTEN=%s; health probe falls back to %s\n' \
      "${PASEO_LISTEN:-}" "$PASEO_HEALTH_URL" >&2
  fi
fi
DOCKER_SOCK="${AGENT_DEVBOX_DOCKER_SOCK:-/var/run/docker.sock}"
DOCKER_BIN="${AGENT_DEVBOX_DOCKER_BIN:-/usr/bin/docker}"
CURL_BIN="${AGENT_DEVBOX_CURL_BIN:-/usr/bin/curl}"
SETSID_BIN="${AGENT_DEVBOX_SETSID_BIN:-/usr/bin/setsid}"
# /proc is overridable so the bats suite can serve fake {stat,status,comm,
# cmdline,exe} trees; production always uses /proc.
PROC_FS="${AGENT_DEVBOX_PROC_FS:-/proc}"
# Only the exported WSL rootfs carries this read-only marker (Dockerfile.wsl).
# Its presence, never `command -v dockerd`, decides whether dockerd is required.
OVERLAY_MARKER="${AGENT_DEVBOX_OVERLAY_MARKER:-/etc/agent-devbox-wsl-overlay}"
# ONE monotonic deadline shared by dockerd and paseo, started before the first
# service launch (mount/UUID/bind already done). Both probes use slices clipped
# to what is left of it.
READY_TIMEOUT="${AGENT_DEVBOX_READY_TIMEOUT:-30}"
READY_POLL_MS="${AGENT_DEVBOX_READY_POLL_MS:-2000}"
# Test hooks: a sourceable fake clock, an injected paseo uid/boot id and the
# image node binary. Empty in production.
NOW_MS_CMD="${AGENT_DEVBOX_NOW_MS_CMD:-}"
PASEO_UID_OVERRIDE="${AGENT_DEVBOX_PASEO_UID:-}"
NODE_BIN_OVERRIDE="${AGENT_DEVBOX_NODE_BIN:-}"
# WSL's [boot] command gets no PATH: bash itself resolves names with a built-in
# default, but children (setsid -> execvp) inherit an empty environment PATH and
# fail with ENOENT. Export the standard path once so every child can exec by
# name; the 2026-10-28 install showed `setsid: failed to execute dockerd` on
# every boot because of exactly this.
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
# Boot attach budget: ATTACH_TIMEOUT bounds the interop call (plus 2s kill grace),
# DEVICE_WAIT bounds the single wait for the block device. Worst case ~30s, which
# stays inside the installer's 45s assertion.
ATTACH_TIMEOUT="${AGENT_DEVBOX_ATTACH_TIMEOUT:-8}"
DEVICE_WAIT="${AGENT_DEVBOX_DEVICE_WAIT:-20}"
# Data-disk channel identity: same-channel variants (agents/core) use the SAME
# ext4 label, so a data disk copied within a channel can boot the other variant.
# Labels are per channel (stable `devbox-data`, beta `devbox-data-beta`).
# Precedence: AGENT_DEVBOX_DATA_LABEL (snapshotted below, survives load_conf's
# reset) > conf DATA_LABEL > `devbox-data`. Resolve by UUID first, then by label.
# A copied VHDX keeps the source UUID, so the original and its copy can be
# attached together -> multiple matches are an ERROR, never a coin flip.
DATA_LABEL_ENV="${AGENT_DEVBOX_DATA_LABEL:-}"
DATA_LABEL="${DATA_LABEL_ENV:-devbox-data}"

# Installer-populated values (reloaded by load_conf). Pre-declared empty so the
# functions stay safe under `set -u` even when called directly, or when the file
# is sourced without main()/load_conf() first.
DATA_VHDX=""
DATA_UUID=""
DATA_DISTRO=""
PASEO_PASSWORD=""
# "" normally, so the maintenance MOTD renders a blank line; set by
# fail_ambiguous_data_disk() to explain the two-device case in the banner.
MOTD_HINT=""
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
# then resolve the channel label, the mount name and the concrete DATADIR, and
# export PASEO_PASSWORD for the daemon child. Resetting DATA_LABEL BEFORE the
# source keeps a second call from leaking the previous conf's label; the env
# override is snapshotted at source time (DATA_LABEL_ENV) and re-applied AFTER
# the source, because sourcing the conf would otherwise clobber it. The data
# disk is resolved by UUID first, then by the channel label (DATA_LABEL), so
# same-channel VHDX files are interchangeable; more than one match fails closed.
load_conf() {
  DATA_VHDX=""
  DATA_UUID=""
  DATA_DISTRO=""
  PASEO_PASSWORD=""
  DATA_LABEL="devbox-data"
  CONF_MISSING=0
  # shellcheck source=/dev/null
  if [ -f "$CONF" ]; then
    . "$CONF"
  else
    CONF_MISSING=1
  fi
  DATA_LABEL="${DATA_LABEL_ENV:-${DATA_LABEL:-devbox-data}}"
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

# data_devs(): print the attached device(s) for the data disk. UUID wins whenever
# it matches anything: two variants' own disks have different UUIDs, so both can
# stay attached without being mistaken for each other. Only when the UUID is
# absent (a disk copied from another variant in the same channel) does the
# channel label apply.
# `-t UUID=` (not -U) on purpose: a copied VHDX keeps the source UUID, so all
# devices sharing it must be enumerated for the multi-match guard to see them.
data_devs() {
  local devs
  if [ -n "${DATA_UUID:-}" ]; then
    devs="$(blkid -o device -t "UUID=$DATA_UUID" 2>/dev/null || true)"
    if [ -n "$devs" ]; then
      printf '%s\n' "$devs"
      return 0
    fi
  fi
  devs="$(blkid -o device -t "LABEL=$DATA_LABEL" 2>/dev/null || true)"
  [ -n "$devs" ] || return 1
  printf '%s\n' "$devs"
}

# data_dev(): exactly one device, else fail closed.
#   0 = one device on stdout, 1 = none, 2 = ambiguous (devices echoed to stderr)
data_dev() {
  local devs n
  devs="$(data_devs)" || return 1
  n="$(printf '%s\n' "$devs" | wc -l)"
  if [ "$n" -ne 1 ]; then
    printf '%s\n' "$devs" >&2
    return 2
  fi
  printf '%s\n' "$devs"
}

# data_source(): uuid | label — which identity resolved the device.
data_source() {
  if [ -n "${DATA_UUID:-}" ] && [ -n "$(blkid -o device -t "UUID=$DATA_UUID" 2>/dev/null || true)" ]; then
    printf 'uuid\n'
  else
    printf 'label\n'
  fi
}

# device_id(): kernel major:minor of a block device, via lsblk (util-linux).
# `stat -c %t:%T` prints HEX without a 2-digit normalisation, so it is
# deliberately not used here. Leading/trailing whitespace is trimmed; an empty
# answer means the device cannot be identified and the caller must fail closed.
device_id() {
  local dev="${1:-}" id
  [ -n "$dev" ] || return 1
  id="$(lsblk -no MAJ:MIN -- "$dev" 2>/dev/null | awk 'NF { print $1; exit }')"
  id="${id//[[:space:]]/}"
  case "$id" in
    '' | *[!0-9:]*) return 1 ;;
    *:*:*) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$id"
}

# pair_value(KEY, "KEY=..."): extract one value from `findmnt --pairs` output.
# Values are quoted, so empty UUID/LABEL columns keep their boundaries (raw
# `findmnt -r` collapses them, shifting MAJ:MIN into the wrong field).
pair_value() {
  local key="$1" line="$2" re
  re="(^|[[:space:]])${key}=\"([^\"]*)\""
  if [[ $line =~ $re ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# has_mount_option(OPT, OPTS): exact comma-separated option match. `ro` inside
# e.g. `errors=remount-ro` must NOT count as read-only (nor `rw` as a substring).
has_mount_option() {
  printf '%s\n' "${2:-}" | tr ',' '\n' | grep -Fxq -- "$1"
}

# fail_closed_identity(): shared tail of an identity-verification failure.
fail_closed_identity() {
  log "boot failed: maintenance mode"
  write_maintenance_motd
}

# verify_mounted_data_disk(DEV[, MAJ:MIN]): authoritative identity check for
# $DATADIR. A live mountpoint is not enough: the filesystem must be ext4, mounted
# read-write, on the SAME kernel device we resolved (major:minor), and carry the
# configured identity (exact UUID when DATA_UUID is set, else the channel LABEL).
# Used by BOTH the already-mounted fast path and the fresh-mount path, so a
# stale/wrong/read-only mount can never seed or bind. Failures log the existing
# `boot failed: maintenance mode`, write the repair banner and return 1.
# Never formats, unmounts or remounts; it only inspects.
verify_mounted_data_disk() {
  local dev="${1:-}" want_id="${2:-}" out n src fstype opts uuid label majmin sid
  if [ -z "$dev" ]; then
    log "FATAL: 挂载校验缺少已解析的数据盘设备"
    fail_closed_identity
    return 1
  fi
  if [ -z "$want_id" ]; then
    want_id="$(device_id "$dev")" || want_id=""
  fi
  if [ -z "$want_id" ]; then
    log "FATAL: 无法获取数据盘 $dev 的 major:minor，拒绝信任该挂载"
    fail_closed_identity
    return 1
  fi
  # --pairs (not raw): empty UUID/LABEL columns keep their field boundaries.
  out="$(findmnt -Pno SOURCE,FSTYPE,OPTIONS,UUID,LABEL,MAJ:MIN --mountpoint "$DATADIR" 2>/dev/null)"
  n=0
  if [ -n "$out" ]; then
    n="$(printf '%s\n' "$out" | wc -l)"
  fi
  if [ "$n" -ne 1 ]; then
    log "FATAL: 挂载校验失败：$DATADIR 的挂载记录不是恰好一条（found=$n）"
    fail_closed_identity
    return 1
  fi
  src="$(pair_value SOURCE "$out")" || src=""
  fstype="$(pair_value FSTYPE "$out")" || fstype=""
  opts="$(pair_value OPTIONS "$out")" || opts=""
  uuid="$(pair_value UUID "$out")" || uuid=""
  label="$(pair_value LABEL "$out")" || label=""
  majmin="$(pair_value MAJ:MIN "$out")" || majmin=""
  if [ "$fstype" != "ext4" ]; then
    log "FATAL: 挂载校验失败：FSTYPE=$fstype，期望 ext4（$DATADIR）"
    fail_closed_identity
    return 1
  fi
  if ! has_mount_option rw "$opts" || has_mount_option ro "$opts"; then
    log "FATAL: 挂载校验失败：OPTIONS=$opts，期望可写（rw 且无 ro）"
    fail_closed_identity
    return 1
  fi
  if [ "$majmin" != "$want_id" ]; then
    log "FATAL: 挂载校验失败：MAJ:MIN=$majmin，期望 $want_id（$dev）（设备身份不匹配）"
    fail_closed_identity
    return 1
  fi
  if [ "$src" != "$dev" ]; then
    sid="$(device_id "$src")" || sid=""
    if [ -z "$sid" ] || [ "$sid" != "$want_id" ]; then
      log "FATAL: 挂载校验失败：SOURCE=$src 不是已解析设备 $dev（major:minor=$want_id）"
      fail_closed_identity
      return 1
    fi
  fi
  if [ -n "${DATA_UUID:-}" ]; then
    if [ "$uuid" != "$DATA_UUID" ]; then
      # Never accept a differing UUID via the shared label fallback.
      log "FATAL: data disk UUID mismatch (mounted='$uuid' expected='$DATA_UUID')（数据盘 UUID 不匹配；不接受标签替代）"
      fail_closed_identity
      return 1
    fi
  else
    if [ -z "${DATA_LABEL:-}" ] || [ "$label" != "$DATA_LABEL" ]; then
      log "FATAL: 挂载校验失败：LABEL='$label'，期望 '$DATA_LABEL'（数据盘标签不匹配）"
      fail_closed_identity
      return 1
    fi
  fi
  return 0
}

# fail_ambiguous_data_disk(): two attached devices share UUID/label, usually a
# copied VHDX whose original is still attached. Never mount either one.
fail_ambiguous_data_disk() {
  log "检测到多块 UUID/标签相同的数据盘（常见原因：复制了另一个变体的 data.vhdx，且原盘仍处于附加状态）"
  log "请先运行安装目录里的 unmount-datadisk.cmd 分离多余的一块，再重新打开发行版"
  log "boot failed: maintenance mode"
  MOTD_HINT="注意：检测到多块 UUID/标签相同的数据盘。先运行安装目录里的 unmount-datadisk.cmd 分离多余的一块，再重新打开发行版。"
}

# wait_device(N): wait up to N seconds (default DEVICE_WAIT) for the data disk
# device to resolve by UUID or shared label. Counter loop, not a wall-clock
# deadline: tests shim `sleep` to return instantly, so only a fixed iteration
# count stays bounded. Returns 2 as soon as the identity is ambiguous.
wait_device() {
  local n="${1:-$DEVICE_WAIT}" i=0 rc
  while [ "$i" -lt "$n" ]; do
    rc=0
    data_dev >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 2 ]; then
      return 2
    fi
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# attach_vhdx(): start the ONE allowed interop call (bare attach). It only
# STARTS the attach — it never waits and never decides success: the single
# wait_device() in ensure_mounted() is the judge. Returns 1 when disabled or
# when interop is unavailable, 0 otherwise.
attach_vhdx() {
  local raw rc tmp human pre
  if [ "${AGENT_DEVBOX_BOOT_ATTACH:-1}" != "1" ]; then
    log "boot attach 已禁用（AGENT_DEVBOX_BOOT_ATTACH=0）"
    return 1
  fi
  pre=0
  data_dev >/dev/null 2>&1 || pre=$?
  case "$pre" in
    0)
      log "数据盘设备已存在（attach_source=preexisting），跳过 boot attach"
      return 0 ;;
    2)
      log "警告：检测到多块数据盘（UUID/标签重复），跳过 boot attach"
      return 0 ;;
  esac
  [ -n "${DATA_VHDX:-}" ] || return 1
  # Redirect to a file instead of capturing via $(...): the interop output is
  # UTF-16LE, and a command substitution would drop its NUL bytes with a bash
  # warning ("ignored null byte in input") — that noise went straight into the
  # boot log. A file also lets us decode it for humans below.
  tmp="${TMPDIR:-/tmp}/agent-devbox-attach.$$"
  # PATH lookup first; System32 is the fallback because the [boot] environment
  # has a minimal PATH and interop does not necessarily export it.
  PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}:/mnt/c/Windows/System32" \
    timeout -k 2 "$ATTACH_TIMEOUT" wsl.exe --mount --vhd "$DATA_VHDX" --bare >"$tmp" 2>&1
  rc=$?
  # ASCII-visible form (UTF-16LE drops its NULs) — used for matching only.
  raw="$(tr -d '\000' < "$tmp" 2>/dev/null)"
  # Human form: decode UTF-16LE when iconv exists; otherwise keep the raw form.
  human="$raw"
  if command -v iconv >/dev/null 2>&1; then
    if iconv -f UTF-16LE -t UTF-8 "$tmp" >"$tmp.u" 2>/dev/null; then
      human="$(cat "$tmp.u")"
    fi
  fi
  rm -f "$tmp" "$tmp.u"
  if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    log "警告：找不到 WSL 互操作程序（interop 不可用），请用维护模式提示的命令手动附加"
    return 1
  fi
  case "$raw" in
    *ALREADY_ATTACHED*|*0x80040312*)
      log "VHDX 已附加（attach_source=preexisting, rc=$rc）" ;;
    "")
      log "boot attach 返回 rc=$rc（无输出）" ;;
    *)
      log "boot attach 返回 rc=$rc：$human" ;;
  esac
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    log "警告：boot attach 超时（${ATTACH_TIMEOUT}s + 2s kill grace）"
  fi
  return 0
}

# ensure_mounted(): attach (only when the device is missing), wait ONCE for the
# block device, mount by hand, confirm. Returns 0 the moment $DATADIR is
# mounted, else 1 after a `boot failed: maintenance mode` line. Every step is
# logged; none is fatal by itself.
ensure_mounted() {
  local dev r w want_id redev reid

  # 1) already mounted -> verify ext4/rw/identity; a bare mountpoint is not enough.
  if is_mounted; then
    log "数据盘已挂载于 $DATADIR，正在校验挂载身份"
    r=0
    dev="$(data_dev 2>/dev/null)" || r=$?
    if [ "$r" -ne 0 ]; then
      if [ "$r" -eq 2 ]; then
        fail_ambiguous_data_disk
      else
        log "FATAL: 数据盘已挂载，但无法唯一解析其设备（rc=$r），拒绝信任该挂载"
        fail_closed_identity
      fi
      return 1
    fi
    want_id="$(device_id "$dev")" || want_id=""
    if [ -z "$want_id" ]; then
      log "FATAL: 数据盘已挂载，但无法获取 $dev 的 major:minor，拒绝信任该挂载"
      fail_closed_identity
      return 1
    fi
    verify_mounted_data_disk "$dev" "$want_id" || return 1
    log "数据盘挂载身份校验通过（$dev, major:minor=$want_id）"
    return 0
  fi

  # 2) no VHDX configured -> cannot attach and cannot mount.
  if [ -z "$DATA_VHDX" ]; then
    if [ "$CONF_MISSING" -eq 1 ]; then
      log "$CONF 尚未写入（首次导入，等待安装器写入并重启）"
    else
      log "未配置 DATA_VHDX，无法挂载数据盘"
      log "boot failed: maintenance mode"
    fi
    return 1
  fi

  # 3) resolve by UUID, then by the shared ext4 label (interchangeable disks).
  #    Two matches are ambiguous -> fail closed, never pick one.
  log "正在查找数据盘设备… (uuid=${DATA_UUID:-未配置}, label=$DATA_LABEL)"
  r=0
  dev="$(data_dev 2>/dev/null)" || r=$?
  if [ "$r" -eq 2 ]; then
    fail_ambiguous_data_disk
    return 1
  fi
  if [ "$r" -eq 0 ]; then
    log "数据盘设备已存在：$dev（attach_source=preexisting, source=$(data_source)）"
  else
    # 4) missing -> attach, then the ONE device wait for this boot.
    log "数据盘设备不存在，尝试在发行版内附加 VHDX（attach_source=boot）"
    if ! attach_vhdx; then
      log "警告：boot attach 未成功，继续等待设备出现"
    fi
    w=0
    wait_device "$DEVICE_WAIT" || w=$?
    if [ "$w" -eq 2 ]; then
      fail_ambiguous_data_disk
      return 1
    fi
    if [ "$w" -ne 0 ]; then
      log "未找到 UUID=${DATA_UUID:-未配置} / 标签=$DATA_LABEL 的数据盘设备"
      log "boot failed: maintenance mode"
      return 1
    fi
    dev="$(data_dev 2>/dev/null)"
    log "数据盘设备已出现：$dev（source=$(data_source)）"
  fi

  # 5) capture the identity of the resolved device, then re-resolve immediately
  #    before mounting: it must still be the SAME single device with the SAME
  #    kernel major:minor. A copied disk attached meanwhile (or a reused device
  #    path) must never be mounted.
  want_id="$(device_id "$dev")" || want_id=""
  if [ -z "$want_id" ]; then
    log "FATAL: 无法获取数据盘 $dev 的 major:minor，拒绝挂载"
    fail_closed_identity
    return 1
  fi
  r=0
  redev="$(data_dev 2>/dev/null)" || r=$?
  if [ "$r" -ne 0 ]; then
    if [ "$r" -eq 2 ]; then
      fail_ambiguous_data_disk
    else
      log "FATAL: 挂载前数据盘设备消失（此前解析为 $dev）"
      fail_closed_identity
    fi
    return 1
  fi
  reid="$(device_id "$redev")" || reid=""
  if [ "$redev" != "$dev" ] || [ "$reid" != "$want_id" ]; then
    log "FATAL: 数据盘设备在解析后发生变化（$dev [$want_id] -> $redev [${reid:-未知}]），拒绝挂载"
    fail_closed_identity
    return 1
  fi

  # 6) mount the raw device at $DATADIR.
  mkdir -p "$DATADIR"
  if ! mount -t ext4 "$dev" "$DATADIR"; then
    log "挂载 $dev 到 $DATADIR 失败"
    log "boot failed: maintenance mode"
    return 1
  fi

  # 7) verify the fresh mount is really the resolved device (ext4/rw/identity).
  verify_mounted_data_disk "$dev" "$want_id" || return 1
  log "数据盘挂载身份校验通过（$dev, major:minor=$want_id）"
  return 0
}

# install_dir(): Windows install directory implied by DATA_VHDX (strip the last
# backslash-separated component). Empty when the path has no directory part.
install_dir() {
  if [ -n "${DATA_VHDX:-}" ]; then
    case "$DATA_VHDX" in
      *\\*) printf '%s\n' "${DATA_VHDX%\\*}" ;;
    esac
  fi
}

# write_maintenance_motd(): fail-closed notice shown to the user on login. Its
# commands are pasteable INTO THIS WSL TERMINAL first (the install-dir batch via
# cmd.exe, then a terminate + reopen), with a Windows PowerShell fallback and the
# installer one-liner. The same commands go to the boot log, so
# `tail /var/log/agent-devbox-boot.log` alone answers "how do I fix this?".
write_maintenance_motd() {
  local dir distro
  dir="$(install_dir)"
  [ -n "$dir" ] || dir='<安装目录>'
  distro="${DATA_DISTRO:-<你的发行版>}"
  cat > "$MOTD_FILE" <<EOF
*** agent-devbox is in MAINTENANCE MODE / 维护模式 ***
数据盘未挂载，未初始化也未启动服务。
The data disk is not mounted, so nothing was seeded or started.
${MOTD_HINT}
在 WSL 终端里依次运行（复制粘贴即可）：
Run these in this WSL terminal (copy & paste):
  1) cmd.exe /c "$dir\\mount-datadisk.cmd"
  2) wsl.exe --terminate $distro
然后重新打开发行版（boot 会重新附加并挂载）。
Then reopen the distro (boot re-attaches and mounts it).

若互操作不可用，改在 Windows PowerShell 里运行：
If interop is unavailable, run these in Windows PowerShell instead:
  1) $dir\\mount-datadisk.cmd
  2) wsl --terminate $distro

若数据盘还没创建，也可以重跑 Windows 安装脚本：
If the disk was never created, re-run the Windows installer:
  irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
EOF
  log "修复步骤 1)：cmd.exe /c \"$dir\\mount-datadisk.cmd\""
  log "修复步骤 2)：wsl.exe --terminate $distro"
}

# clear_motd(): drop any stale maintenance notice on a healthy boot. Best effort;
# it never masks anything else.
clear_motd() {
  : > "$MOTD_FILE"
}

# ensure_cgroup2(): dockerd needs cgroup v2. WSL normally mounts it itself; this
# is only a best-effort fallback and NEVER fails boot.
ensure_cgroup2() {
  if findmnt -rn -t cgroup2 /sys/fs/cgroup >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p /sys/fs/cgroup
  if mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null; then
    log "已挂载 cgroup2 到 /sys/fs/cgroup"
    return 0
  fi
  log "警告：cgroup2 未挂载，dockerd 可能启动失败（不影响 boot）"
  return 1
}

# now_ms(): millisecond clock for the shared readiness deadline. NOW_MS_CMD is a
# test hook: the suite shims it with an advanceable counter, because a real 30s
# wait would make every main() case slow and time-dependent.
now_ms() {
  local t
  if [ -n "$NOW_MS_CMD" ]; then
    "$NOW_MS_CMD"
    return 0
  fi
  t="${EPOCHREALTIME:-}"
  if [ -n "$t" ]; then
    t="${t/[.,]/}"
    printf '%s\n' "$((t / 1000))"
    return 0
  fi
  printf '%s000\n' "$(date +%s)"
}

ms_to_s() {
  printf '%s.%03d\n' "$(($1 / 1000))" "$(($1 % 1000))"
}

# /proc/<pid>/stat: reject zombies and expose the kernel starttime. Field 22 of
# the whole line is field 20 after the LAST ") " — comm may itself contain ") ".
proc_stat_state_start() {
  local pid="$1" stat rest
  stat="$(cat "$PROC_FS/$pid/stat" 2>/dev/null)" || return 1
  rest="${stat##*) }"
  printf '%s\n' "$rest" | awk '{print $1 " " $20}'
}

proc_uid_pair() {
  awk '/^Uid:/ {print $2 " " $3; exit}' "$PROC_FS/$1/status" 2>/dev/null
}

proc_comm() {
  tr -d '\n' 2>/dev/null < "$PROC_FS/$1/comm"
}

proc_title() {
  tr '\0' '\n' 2>/dev/null < "$PROC_FS/$1/cmdline" | sed -n '1p'
}

proc_argv_has() {
  tr '\0' '\n' 2>/dev/null < "$PROC_FS/$1/cmdline" | grep -Fxq -- "$2"
}

proc_exe() {
  local exe
  exe="$(readlink "$PROC_FS/$1/exe" 2>/dev/null)" || return 1
  printf '%s\n' "${exe% (deleted)}"
}

paseo_expected_uid() {
  if [ -n "$PASEO_UID_OVERRIDE" ]; then
    printf '%s\n' "$PASEO_UID_OVERRIDE"
    return 0
  fi
  id -u "$PASEO_USER" 2>/dev/null
}

node_exe() {
  local bin
  if [ -n "$NODE_BIN_OVERRIDE" ]; then
    bin="$NODE_BIN_OVERRIDE"
  else
    bin="$(command -v node 2>/dev/null)"
  fi
  [ -n "$bin" ] || return 1
  readlink -f "$bin" 2>/dev/null || printf '%s\n' "$bin"
}

current_boot_id() {
  if [ -n "${AGENT_DEVBOX_BOOT_ID:-}" ]; then
    printf '%s\n' "$AGENT_DEVBOX_BOOT_ID"
    return 0
  fi
  [ -r "$PROC_FS/sys/kernel/random/boot_id" ] || return 1
  tr -d '\n' < "$PROC_FS/sys/kernel/random/boot_id"
}

# read_paseo_lock(): compact JSON written by the paseo Supervisor. Emit the six
# fields joined by a non-whitespace separator so empty listen/serverId survive
# `read`. Invalid/truncated JSON is a retry, never a death verdict.
read_paseo_lock() {
  jq -er '
    select((.pid | type) == "number" and .pid > 0 and .pid == (.pid | floor))
    | [ (.pid | tostring), (.startedAt // ""), ((.uid // "") | tostring),
        (.bootId // ""), (.listen // ""), (.serverId // "") ]
    | join("\u001f")
  ' "$PASEO_PID" 2>/dev/null
}

# paseo_identity_ok <pid> <json-uid> <json-boot-id> <expected-starttime>
#   0 = the recorded PID is this boot's paseo Supervisor and nothing else
#   2 = process gone/zombie, 3 = identity conflict (uid/comm/title/exe/starttime)
paseo_identity_ok() {
  local pid="$1" juid="$2" jboot="$3" want_start="$4"
  local st state start ids uid_real uid_eff exe want_uid cur_boot node
  want_uid="$(paseo_expected_uid)" || return 3
  if [ "$juid" != "$want_uid" ]; then
    return 3
  fi
  cur_boot="$(current_boot_id 2>/dev/null || true)"
  if [ -n "$jboot" ] && [ -n "$cur_boot" ] && [ "$jboot" != "$cur_boot" ]; then
    return 3
  fi
  st="$(proc_stat_state_start "$pid")" || return 2
  state="${st%% *}"
  start="${st#* }"
  [ "$state" != "Z" ] || return 2
  [ -n "$start" ] || return 2
  if [ -n "$want_start" ] && [ "$start" != "$want_start" ]; then
    return 3
  fi
  ids="$(proc_uid_pair "$pid")"
  uid_real="${ids%% *}"
  uid_eff="${ids##* }"
  if [ "$uid_real" != "$want_uid" ] || [ "$uid_eff" != "$want_uid" ]; then
    return 3
  fi
  [ "$(proc_comm "$pid")" = "Paseo Superviso" ] || return 3
  [ "$(proc_title "$pid")" = "Paseo Supervisor" ] || return 3
  exe="$(proc_exe "$pid")" || return 3
  node="$(node_exe)" || return 3
  [ "$exe" = "$node" ] || return 3
  PASEO_CUR_START="$start"
  return 0
}

read_dockerd_pid() {
  local raw pid
  [ -r "$DOCKERD_PID" ] || return 1
  raw="$(cat "$DOCKERD_PID" 2>/dev/null)" || return 1
  raw="${raw%$'\n'}"
  case "$raw" in
    ''|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  case "$raw" in
    *[!0-9]*) return 1 ;;
  esac
  [ "${#raw}" -le 10 ] || return 1
  pid=$((10#$raw))
  [ "$pid" -gt 0 ] || return 1
  printf '%s\n' "$pid"
}

resolve_dockerd() {
  local bin="${DOCKERD_BIN-dockerd}"
  # An explicitly empty value means "this image has no engine"; never fall back.
  [ -n "$bin" ] || return 1
  case "$bin" in
    /*) [ -x "$bin" ] || return 1 ;;
    *) bin="$(command -v "$bin" 2>/dev/null)" || true ;;
  esac
  if [ -z "$bin" ]; then
    [ -x /usr/sbin/dockerd ] || return 1
    bin=/usr/sbin/dockerd
  fi
  # /proc/<pid>/exe is the real file, so compare against the resolved target
  # (Debian symlinks /usr/bin/dockerd to /usr/sbin/dockerd).
  readlink -f "$bin" 2>/dev/null || printf '%s\n' "$bin"
}

# verify_dockerd_identity <pid> <expected-starttime>
#   0 = real dockerd from this image (uid 0), 2 = gone/zombie, 3 = conflict
verify_dockerd_identity() {
  local pid="$1" want_start="$2" st state start ids uid_real uid_eff exe
  st="$(proc_stat_state_start "$pid")" || return 2
  state="${st%% *}"
  start="${st#* }"
  [ "$state" != "Z" ] || return 2
  [ -n "$start" ] || return 2
  if [ -n "$want_start" ] && [ "$start" != "$want_start" ]; then
    return 3
  fi
  ids="$(proc_uid_pair "$pid")"
  uid_real="${ids%% *}"
  uid_eff="${ids##* }"
  if [ "$uid_real" != "0" ] || [ "$uid_eff" != "0" ]; then
    return 3
  fi
  [ "$(proc_comm "$pid")" = "dockerd" ] || return 3
  exe="$(proc_exe "$pid")" || return 3
  [ "$exe" = "$DOCKERD_ABS" ] || return 3
  proc_argv_has "$pid" "--pidfile" || return 3
  proc_argv_has "$pid" "$DOCKERD_PID" || return 3
  DOCKERD_CUR_START="$start"
  return 0
}

# start_dockerd(): launch at most once. A live, correctly identified engine is
# only probed; an identity conflict fails closed and is never killed/overwritten.
# Returns 0 (started or already running) or 2 with READY_REASON set.
start_dockerd() {
  local pid fd rc
  if ! DOCKERD_ABS="$(resolve_dockerd)"; then
    READY_REASON="missing-binary"
    return 2
  fi
  if pid="$(read_dockerd_pid)"; then
    if verify_dockerd_identity "$pid" ""; then
      DOCKERD_START="$DOCKERD_CUR_START"
      log "dockerd 已在运行（pid=$pid），只探测不重启"
      return 0
    fi
    if [ -e "$PROC_FS/$pid" ]; then
      READY_REASON="identity"
      return 2
    fi
    if [ "$(read_dockerd_pid 2>/dev/null)" = "$pid" ]; then
      rm -f "$DOCKERD_PID" 2>/dev/null || true
    fi
  fi
  ensure_cgroup2 || true
  rotate_log "$DOCKERD_LOG" "$DOCKERD_LOG_MAX"
  if ! { exec {fd}>>"$DOCKERD_LOG"; } 2>/dev/null; then
    READY_REASON="log-open"
    return 2
  fi
  "$SETSID_BIN" --fork "$DOCKERD_ABS" --pidfile "$DOCKERD_PID" </dev/null >&"$fd" 2>&1
  rc=$?
  exec {fd}>&-
  if [ "$rc" -ne 0 ]; then
    READY_REASON="launch"
    return 2
  fi
  log "启动 dockerd（后台，日志 $DOCKERD_LOG）"
  return 0
}

# probe_dockerd <slice-ms>: 0 ready, 1 retry, 2 fatal (READY_REASON set).
probe_dockerd() {
  local slice_ms="$1" slice_s pid rc
  DOCKERD_READY=0
  if ! pid="$(read_dockerd_pid)"; then
    if [ -n "$DOCKERD_START" ] && [ ! -e "$DOCKERD_PID" ]; then
      READY_REASON="exited"
      return 2
    fi
    READY_REASON="pending"
    return 1
  fi
  verify_dockerd_identity "$pid" "$DOCKERD_START"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    READY_REASON="exited"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    READY_REASON="identity"
    return 2
  fi
  [ -n "$DOCKERD_START" ] || DOCKERD_START="$DOCKERD_CUR_START"
  [ -S "$DOCKER_SOCK" ] || { READY_REASON="pending"; return 1; }
  slice_s="$(ms_to_s "$slice_ms")"
  if ! env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    timeout -s KILL "$slice_s" "$DOCKER_BIN" --host "unix:///var/run/docker.sock" info >/dev/null 2>&1; then
    READY_REASON="pending"
    return 1
  fi
  verify_dockerd_identity "$pid" "$DOCKERD_START"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    READY_REASON="exited"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    READY_REASON="identity"
    return 2
  fi
  DOCKERD_READY=1
  return 0
}

# probe_paseo <slice-ms>: 0 ready, 1 retry, 2 fatal (READY_REASON set).
probe_paseo() {
  local slice_ms="$1" slice_s code line pid startedAt juid jboot listen serverId
  local pid2 started2 juid2 jboot2 rc
  if ! line="$(read_paseo_lock)"; then
    if [ -n "$PASEO_LOCK_START" ] && [ ! -e "$PASEO_PID" ]; then
      READY_REASON="exited"
      return 2
    fi
    READY_REASON="pending"
    return 1
  fi
  IFS=$'\x1f' read -r pid startedAt juid jboot listen serverId <<< "$line"
  [ -n "$pid" ] || { READY_REASON="pending"; return 1; }
  paseo_identity_ok "$pid" "$juid" "$jboot" "$PASEO_LOCK_START"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    if [ -n "$PASEO_LOCK_START" ]; then
      READY_REASON="exited"
      return 2
    fi
    READY_REASON="pending"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    READY_REASON="identity"
    return 2
  fi
  if [ -z "$PASEO_LOCK_START" ]; then
    PASEO_LOCK_START="$PASEO_CUR_START"
    PASEO_LOCK_BOOT="$jboot"
    PASEO_LOCK_STARTED_AT="$startedAt"
  fi
  if [ "$jboot" != "$PASEO_LOCK_BOOT" ] || [ "$startedAt" != "$PASEO_LOCK_STARTED_AT" ]; then
    READY_REASON="identity"
    return 2
  fi
  if [ -z "$listen" ] || [ -z "$serverId" ]; then
    READY_REASON="pending"
    return 1
  fi
  slice_s="$(ms_to_s "$slice_ms")"
  code="$(env NO_PROXY='*' no_proxy='*' "$CURL_BIN" -q --noproxy '*' -sS -o /dev/null \
    -w '%{http_code}' --max-time "$slice_s" "$PASEO_HEALTH_URL" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ "$code" != "200" ]; then
    READY_REASON="pending"
    return 1
  fi
  if ! line="$(read_paseo_lock)"; then
    READY_REASON="pending"
    return 1
  fi
  IFS=$'\x1f' read -r pid2 started2 juid2 jboot2 _ <<< "$line"
  if [ "$pid2" != "$pid" ] || [ "$started2" != "$startedAt" ] || [ "$jboot2" != "$jboot" ]; then
    READY_REASON="identity"
    return 2
  fi
  paseo_identity_ok "$pid2" "$juid2" "$jboot2" "$PASEO_LOCK_START"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    READY_REASON="exited"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    READY_REASON="identity"
    return 2
  fi
  return 0
}

start_paseo() {
  local line pid startedAt juid jboot listen serverId fd rc
  if [ ! -x "$PASEO_BOOT_BIN" ]; then
    READY_REASON="missing-binary"
    return 2
  fi
  if line="$(read_paseo_lock)"; then
    IFS=$'\x1f' read -r pid startedAt juid jboot listen serverId <<< "$line"
    if paseo_identity_ok "$pid" "$juid" "$jboot" ""; then
      PASEO_LOCK_START="$PASEO_CUR_START"
      PASEO_LOCK_BOOT="$jboot"
      PASEO_LOCK_STARTED_AT="$startedAt"
      log "paseo 服务已在运行（pid=$pid），只探测不重启"
      return 0
    fi
  fi
  rotate_log "$PASEO_LOG" "$PASEO_LOG_MAX"
  if ! { exec {fd}>>"$PASEO_LOG"; } 2>/dev/null; then
    READY_REASON="log-open"
    return 2
  fi
  "$SETSID_BIN" --fork "$PASEO_BOOT_BIN" </dev/null >&"$fd" 2>&1
  rc=$?
  exec {fd}>&-
  if [ "$rc" -ne 0 ]; then
    READY_REASON="launch"
    return 2
  fi
  log "启动 paseo 服务（后台，日志 $PASEO_LOG）"
  return 0
}

write_service_failure_motd() {
  local service="$1" reason="$2" logpath="$3"
  {
    printf '%s\n' '*** agent-devbox is in MAINTENANCE MODE / 维护模式 ***'
    printf '数据盘已挂载；%s 未就绪。 Data disk mounted; %s not ready.\n' "$service" "$service"
    printf '原因 / reason: %s\n' "$reason"
    printf '日志 / log: %s\n' "$logpath"
  } > "$MOTD_FILE" 2>/dev/null || true
}

# readiness_fail(): never a data-disk banner — the disk IS mounted. The matching
# service log gets the machine-readable line; if that log cannot be opened the
# boot log carries it instead. No password, no remount hint, no "complete".
readiness_fail() {
  local service="$1" reason="$2" logpath
  if [ "$service" = "dockerd" ]; then
    logpath="$DOCKERD_LOG"
  else
    logpath="$PASEO_LOG"
  fi
  if ! printf '%s\n' "readiness failed: service=$service reason=$reason" >> "$logpath" 2>/dev/null; then
    log "readiness failed: service=$service reason=$reason（无法写入 $logpath）"
  fi
  write_service_failure_motd "$service" "$reason" "$logpath"
  log "boot failed: service=$service reason=$reason log=$logpath"
}

# ensure_services_ready(): one 30s deadline for every required service. Overlay
# marker => dockerd AND paseo; absent => paseo only (never infer from PATH).
ensure_services_ready() {
  local docker_required=0 deadline rem_ms slice_ms sleep_s rc dsv_rc psv_rc
  PASEO_LOCK_START=""
  PASEO_LOCK_BOOT=""
  PASEO_LOCK_STARTED_AT=""
  DOCKERD_START=""
  DOCKERD_READY=0
  if [ -f "$OVERLAY_MARKER" ]; then
    docker_required=1
  fi
  deadline=$(( $(now_ms) + READY_TIMEOUT * 1000 ))
  if [ "$docker_required" -eq 1 ]; then
    start_dockerd
    rc=$?
    if [ "$rc" -eq 2 ]; then
      readiness_fail dockerd "$READY_REASON"
      return 1
    fi
  fi
  start_paseo
  rc=$?
  if [ "$rc" -eq 2 ]; then
    readiness_fail paseo "$READY_REASON"
    return 1
  fi
  while :; do
    rem_ms=$(( deadline - $(now_ms) ))
    if [ "$rem_ms" -le 0 ]; then
      if [ "$docker_required" -eq 1 ] && [ "$DOCKERD_READY" -ne 1 ]; then
        readiness_fail dockerd timeout
      else
        readiness_fail paseo timeout
      fi
      return 1
    fi
    slice_ms="$READY_POLL_MS"
    if [ "$slice_ms" -gt "$rem_ms" ]; then
      slice_ms="$rem_ms"
    fi
    dsv_rc=0
    if [ "$docker_required" -eq 1 ]; then
      probe_dockerd "$slice_ms"
      dsv_rc=$?
      if [ "$dsv_rc" -eq 2 ]; then
        readiness_fail dockerd "$READY_REASON"
        return 1
      fi
    fi
    probe_paseo "$slice_ms"
    psv_rc=$?
    if [ "$psv_rc" -eq 2 ]; then
      readiness_fail paseo "$READY_REASON"
      return 1
    fi
    if [ "$dsv_rc" -eq 0 ] && [ "$psv_rc" -eq 0 ]; then
      clear_motd
      log "boot complete"
      return 0
    fi
    rem_ms=$(( deadline - $(now_ms) ))
    if [ "$rem_ms" -le 0 ]; then
      continue
    fi
    slice_ms="$READY_POLL_MS"
    if [ "$slice_ms" -gt "$rem_ms" ]; then
      slice_ms="$rem_ms"
    fi
    sleep_s="$(ms_to_s "$slice_ms")"
    sleep "$sleep_s"
  done
}

# verify_data_uuid(): compare the mounted UUID(s) with DATA_UUID. `sort -u`
# collapses the same device stacked twice by a boot race; two DIFFERENT UUIDs
# still produce two lines and fail closed. Returns 1 after writing the
# maintenance banner. Kept as a small standalone check; boot itself relies on
# the authoritative verify_mounted_data_disk() in ensure_mounted().
verify_data_uuid() {
  [ -n "${DATA_UUID:-}" ] || return 0
  local cur
  cur="$(findmnt -rno UUID --mountpoint "$DATADIR" 2>/dev/null | sort -u)"
  if [ "$cur" != "$DATA_UUID" ]; then
    log "FATAL: data disk UUID mismatch (found='$cur' expected='$DATA_UUID')（数据盘 UUID 不匹配）"
    log "boot failed: maintenance mode"
    write_maintenance_motd
    return 1
  fi
  return 0
}

# main(): the full boot sequence.
main() {
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

  # ensure_mounted() already verified ext4/rw/UUID-or-LABEL and the kernel
  # major:minor identity (both for an existing mount and a fresh one), so there
  # is no second, weaker identity check here.

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
    log "boot failed: maintenance mode"
    write_maintenance_motd
    exit 0
  fi
  chmod 0700 /root

  # --- desktop-app CLI visibility (must run AFTER the binds: /root and /home/*
  # live on the data disk, so an image-side link alone cannot repair an upgrade) -
  ensure_opencode_shim /root /home/*

  # --- required services: the overlay variant needs dockerd AND paseo -------
  # The MOTD is cleared only after every required probe passed in the same
  # round; `boot complete` is emitted exactly once, here, on success.
  ensure_services_ready || exit 0
}

# --- entry point (guarded so the file can be sourced without side effects) ----
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
