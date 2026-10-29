#!/usr/bin/env bash
# =============================================================================
# wsl-session-mount.sh — attach the persistent data disk to the CURRENT session.
#
# WHY THIS EXISTS
#   WSL keeps an elevated and a non-elevated mount namespace per distro. PID 1
#   and the boot-time services live in one; ordinary (non-elevated) terminal
#   sessions share the other. The boot script already mounts the data disk and
#   binds /home, /root and /workspace inside the boot namespace, but the boot
#   binds may be absent in the non-elevated one, where those paths still resolve
#   to the system disk. This helper repeats the same mount + bind in the caller's
#   namespace so an interactive root login sees the persistent homes. It is
#   idempotent: a second terminal (or a session that is already set up) makes
#   ZERO mount calls.
#
# USAGE
#   wsl-session-mount.sh [--force]
#     --force   skip the TTY guard (tests / manual runs). The Docker, non-root
#               and unreadable-conf guards still apply.
#
# EXIT CODES
#   0  already attached, or attached successfully by this run
#   2  usage error (unknown argument)
#   3  skipped: Docker image, non-root, non-interactive without --force, or the
#      config file is not readable
#   4  attempted and failed: invalid mount name/path, shared propagation,
#      device missing or ambiguous, mount failure, UUID/identity mismatch, data
#      disk not initialized, or a bind/verification that did not stick
#
# ENV OVERRIDES (internal/test)
#   AGENT_DEVBOX_CONF             default /etc/agent-devbox.conf
#   AGENT_DEVBOX_DATADIR          default /mnt/$DATA_MNTNAME
#   AGENT_DEVBOX_SESSION_WAIT     device wait in seconds (default 5)
#   AGENT_DEVBOX_SESSION_TARGETS  default "/home /root /workspace"
#   AGENT_DEVBOX_DATA_LABEL       overrides the conf DATA_LABEL (channel label)
#
# SAFETY
#   No Windows interop, no formatting, no detaching, no remounting. The daemon
#   password read from the conf is dropped before any other command runs.
#   Diagnostics go to stderr; the success line is the only stdout output.
#   Deliberately `set -uo pipefail` with NO `-e`: every failure must print its
#   own warning before exiting.
# =============================================================================
set -uo pipefail

# Same PATH handling as the boot script: keep an inherited PATH (the test suite
# prepends its shims) and fall back to the standard system path when absent.
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

CONF="${AGENT_DEVBOX_CONF:-/etc/agent-devbox.conf}"
FORCE=0
mounted_any=0

warn() { printf '%s\n' "$*" >&2; }

usage() { printf '用法: %s [--force]\n' "${0##*/}" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing: only --force exists; anything else is a usage error.
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Guards (in contract order): Docker, TTY unless --force, root, readable conf.
# None of them touch the disk. This process is a script, so its own `$-` never
# carries the interactive flag; the login shell that runs it owns that check.
# ---------------------------------------------------------------------------
if [ "${IS_DOCKER:-false}" = "true" ]; then
  exit 3
fi

if [ "$FORCE" -ne 1 ] && [ ! -t 0 ]; then
  exit 3
fi

if [ "$(id -u)" -ne 0 ]; then
  exit 3
fi

if [ ! -r "$CONF" ]; then
  exit 3
fi

# ---------------------------------------------------------------------------
# Conf: sourced in this process (root:root 0600) and immediately sanitized.
# Pre-declared so `set -u` is safe even if a key is absent.
# ---------------------------------------------------------------------------
DATA_VHDX=""
DATA_UUID=""
DATA_LABEL=""
DATA_MNTNAME=""

# shellcheck source=/dev/null
. "$CONF"
# The daemon password is not needed here and must never linger in this process.
unset PASEO_PASSWORD

MNTNAME="${DATA_MNTNAME:-devbox-data}"
# "wsl" is refused because the default DATADIR would then be the shared
# cross-distro mount directory: never use it for the data disk.
if ! [[ "$MNTNAME" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$MNTNAME" = "." ] || [ "$MNTNAME" = ".." ] || [ "$MNTNAME" = "wsl" ]; then
  warn "警告：数据盘挂载名不合法（$MNTNAME），本次会话不挂载。"
  exit 4
fi

DATADIR="${AGENT_DEVBOX_DATADIR:-/mnt/$MNTNAME}"
case "$DATADIR" in
  /*) ;;
  *)
    warn "警告：数据盘挂载点不是绝对路径（$DATADIR），本次会话不挂载。"
    exit 4
    ;;
esac

TARGETS_RAW="${AGENT_DEVBOX_SESSION_TARGETS:-/home /root /workspace}"
targets=()
read -r -a targets <<< "$TARGETS_RAW"

# ---------------------------------------------------------------------------
# Small probes shared by the fast path and the bind loop.
# ---------------------------------------------------------------------------
path_id() {
  local id
  id="$(stat -c '%d:%i' "$1" 2>/dev/null || true)"
  printf '%s' "$id"
}

same_identity() {
  local a b
  a="$(path_id "$1")"
  b="$(path_id "$2")"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

leaf_of() { printf '%s' "${1##*/}"; }

# ---------------------------------------------------------------------------
# Fast path: this session already looks exactly like a successful run.
# Must come before any probing/mounting so a second terminal is silent.
# ---------------------------------------------------------------------------
fast_path_ready() {
  local target
  mountpoint -q "$DATADIR" || return 1
  for target in "${targets[@]}"; do
    mountpoint -q "$target" || return 1
    same_identity "$DATADIR/$(leaf_of "$target")" "$target" || return 1
  done
  return 0
}

if fast_path_ready; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Propagation guard: a shared parent would leak this mount into other distros.
# An empty PROPAGATION is tolerated (older findmnt / non-mounted parent).
# ---------------------------------------------------------------------------
PARENT="$(dirname "$DATADIR")"
PROPAGATION="$(findmnt -n -o PROPAGATION -T "$PARENT" 2>/dev/null || true)"
case "$PROPAGATION" in
  shared*)
    warn "警告：挂载点父目录是 shared 传播，拒绝挂载（避免影响其它发行版）。"
    exit 4
    ;;
esac

mkdir -p "$DATADIR"

# ---------------------------------------------------------------------------
# Device resolution: UUID first, then the channel label, with a bounded wait
# for the boot-time attach to land. Multiple matches fail closed.
# ---------------------------------------------------------------------------
SESSION_WAIT="${AGENT_DEVBOX_SESSION_WAIT:-5}"
case "$SESSION_WAIT" in
  *[!0-9]*) SESSION_WAIT=5 ;;
esac
LABEL="${AGENT_DEVBOX_DATA_LABEL:-${DATA_LABEL:-devbox-data}}"
DEVICE=""

count_lines() {
  local n=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
  done <<< "$1"
  printf '%s' "$n"
}

# Returns 0 with DEVICE set, 1 when nothing matched, 2 when ambiguous.
select_device() {
  local out n
  DEVICE=""
  if [ -n "${DATA_UUID:-}" ]; then
    out="$(blkid -o device -t "UUID=$DATA_UUID" 2>/dev/null || true)"
    n="$(count_lines "$out")"
    if [ "$n" -gt 1 ]; then
      return 2
    fi
    if [ "$n" -eq 1 ]; then
      DEVICE="$out"
      return 0
    fi
  fi
  out="$(blkid -o device -t "LABEL=$LABEL" 2>/dev/null || true)"
  n="$(count_lines "$out")"
  if [ "$n" -gt 1 ]; then
    return 2
  fi
  if [ "$n" -eq 1 ]; then
    DEVICE="$out"
    return 0
  fi
  return 1
}

attempt=0
while :; do
  select_device
  select_rc=$?
  if [ "$select_rc" -eq 0 ]; then
    break
  fi
  if [ "$select_rc" -eq 2 ]; then
    warn "警告：有多块设备匹配数据盘标识，拒绝挂载。"
    exit 4
  fi
  if [ "$attempt" -ge "$SESSION_WAIT" ]; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done

if [ -z "$DEVICE" ]; then
  if [ -n "${DATA_VHDX:-}" ]; then
    install_dir="${DATA_VHDX%\\*}"
  else
    install_dir='<安装目录>'
  fi
  warn "警告：持久数据盘未附加；本次会话的 /home /root /workspace 仍在系统盘。修复：cmd.exe /c \"$install_dir\\mount-datadisk.cmd\" 后重开终端，或稍后在 Windows 侧运行 wsl --terminate <发行版>。"
  exit 4
fi

# ---------------------------------------------------------------------------
# Mount the data disk read-write, unless this namespace already has it mounted
# (a second ext4 mount would stack it). A failed mount is retried by re-checking
# the mountpoint once: a concurrent terminal may have won the race.
# ---------------------------------------------------------------------------
if mountpoint -q "$DATADIR"; then
  :
elif mount -t ext4 -o rw "$DEVICE" "$DATADIR"; then
  mounted_any=1
elif mountpoint -q "$DATADIR"; then
  :
else
  warn "警告：数据盘挂载失败（设备 $DEVICE，挂载点 $DATADIR）。"
  exit 4
fi

# ---------------------------------------------------------------------------
# Verify identity and that the mount really is read-write.
# ---------------------------------------------------------------------------
if [ -n "${DATA_UUID:-}" ]; then
  got_uuid="$(findmnt -rno UUID --mountpoint "$DATADIR" 2>/dev/null | sort -u | tr -d '\r')"
  if [ "$got_uuid" != "$DATA_UUID" ]; then
    warn "警告：数据盘校验失败（UUID 或绑定不一致）。"
    exit 4
  fi
fi

got_opts="$(findmnt -rno OPTIONS --mountpoint "$DATADIR" 2>/dev/null || true)"
case ",$got_opts," in
  *,rw,*) ;;
  *)
    warn "警告：数据盘校验失败（UUID 或绑定不一致）。"
    exit 4
    ;;
esac

# ---------------------------------------------------------------------------
# Initialization guard: a freshly formatted disk has no seeded homes yet.
# ---------------------------------------------------------------------------
if [ ! -e "$DATADIR/.initialized" ]; then
  warn "警告：数据盘尚未完成初始化，本次会话不绑定；请稍后重开终端。"
  exit 4
fi

# ---------------------------------------------------------------------------
# Bind each target, skipping the ones already bound. Verification is re-checked
# once because another terminal can bind between our probe and our mount.
# ---------------------------------------------------------------------------
for target in "${targets[@]}"; do
  [ -n "$target" ] || continue
  src="$DATADIR/$(leaf_of "$target")"
  if mountpoint -q "$target" && same_identity "$src" "$target"; then
    continue
  fi
  if ! mount --bind "$src" "$target" && ! mountpoint -q "$target"; then
    warn "警告：数据盘绑定失败（$src -> $target）。"
    exit 4
  fi
  if ! same_identity "$src" "$target"; then
    if ! same_identity "$src" "$target"; then
      warn "警告：数据盘校验失败（UUID 或绑定不一致）。"
      exit 4
    fi
  fi
  mounted_any=1
done

# The canonical line is pinned by the contract; print it once, and only when
# this run mounted the device or bound a target (the fast path exits silently
# above).
if [ "$mounted_any" -eq 1 ]; then
  printf '已把持久数据盘接入当前会话：/home /root /workspace\n'
fi

exit 0
