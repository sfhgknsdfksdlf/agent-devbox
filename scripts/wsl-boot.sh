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
  local dev r w

  # 1) already mounted -> nothing to do.
  if is_mounted; then
    log "数据盘已挂载于 $DATADIR，跳过挂载"
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
  data_dev >/dev/null 2>&1 || r=$?
  if [ "$r" -eq 2 ]; then
    fail_ambiguous_data_disk
    return 1
  fi
  if [ "$r" -eq 0 ]; then
    dev="$(data_dev)"
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
    dev="$(data_dev)"
    log "数据盘设备已出现：$dev（source=$(data_source)）"
  fi

  # 5) mount the raw device at $DATADIR.
  mkdir -p "$DATADIR"
  if ! mount -t ext4 "$dev" "$DATADIR"; then
    log "挂载 $dev 到 $DATADIR 失败"
    log "boot failed: maintenance mode"
    return 1
  fi

  # 6) confirm the mount actually took.
  if is_mounted; then
    return 0
  fi
  log "挂载后校验失败：$DATADIR 不是挂载点"
  log "boot failed: maintenance mode"
  return 1
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

# start_dockerd(): fire-and-forget start. WSL has systemd disabled, so this is
# the only place the engine can come up. It must never block or fail boot:
# stdin is /dev/null so the [boot] pipe cannot be held open, and no readiness
# wait is performed. Absent binary = no-op (Docker ships only in the rootfs
# overlay, so the stock image simply skips it).
start_dockerd() {
  local bin pid
  bin="${DOCKERD_BIN-dockerd}"
  if [ -z "$bin" ]; then
    log "dockerd 未安装（仅 WSL rootfs 变体带 Docker），跳过"
    return 0
  fi
  # [boot] gets a minimal PATH; Debian ships dockerd in /usr/sbin, so resolve it
  # explicitly instead of trusting PATH to contain sbin.
  if ! command -v "$bin" >/dev/null 2>&1; then
    if [ -x /usr/sbin/dockerd ]; then
      bin=/usr/sbin/dockerd
    else
      log "dockerd 未安装（仅 WSL rootfs 变体带 Docker），跳过"
      return 0
    fi
  fi
  if [ -f "$DOCKERD_PID" ]; then
    pid="$(cat "$DOCKERD_PID" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "dockerd 已在运行（pid=$pid）"
      return 0
    fi
  fi
  ensure_cgroup2 || true
  rotate_log "$DOCKERD_LOG" "$DOCKERD_LOG_MAX"
  log "启动 dockerd（后台，日志 $DOCKERD_LOG）"
  setsid "$bin" </dev/null >>"$DOCKERD_LOG" 2>&1 &
  echo $! > "$DOCKERD_PID"
  return 0
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
      log "boot failed: maintenance mode"
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
    log "boot failed: maintenance mode"
    write_maintenance_motd
    exit 0
  fi
  chmod 0700 /root

  # --- desktop-app CLI visibility (must run AFTER the binds: /root and /home/*
  # live on the data disk, so an image-side link alone cannot repair an upgrade) -
  ensure_opencode_shim /root /home/*

  # --- Docker Engine (rootfs overlay only; fire-and-forget, never blocks) ----
  start_dockerd

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
