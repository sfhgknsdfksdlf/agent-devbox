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
#      config file is missing/unreadable
#   4  attempted and failed: unsafe/invalid config (symlink, non-regular file,
#      wrong owner/group, mode != 0600, malformed or disallowed content),
#      invalid mount name/path, shared propagation, device missing or
#      ambiguous, mount failure, UUID/identity mismatch, data disk not
#      initialized, or a bind/verification that did not stick
#
# ENV OVERRIDES (internal/test)
#   AGENT_DEVBOX_CONF             default /etc/agent-devbox.conf
#   AGENT_DEVBOX_CONF_UID         expected conf owner uid (default 0 = root)
#   AGENT_DEVBOX_CONF_GID         expected conf group gid (default 0 = root)
#     The two owner overrides are TEST-ONLY: they let a non-root CI runner
#     simulate the production root-owned file without chown. The 0600 mode is
#     never overridable.
#   AGENT_DEVBOX_DATADIR          default /mnt/$DATA_MNTNAME
#   AGENT_DEVBOX_SESSION_WAIT     device wait in seconds (default 5)
#   AGENT_DEVBOX_SESSION_TARGETS  default "/home /root /workspace"
#   AGENT_DEVBOX_DATA_LABEL       overrides the conf DATA_LABEL (channel label)
#
# SAFETY
#   The conf is NEVER sourced or evaluated. A strict line parser reads only
#   DATA_UUID / DATA_LABEL / DATA_MNTNAME; PASEO_PASSWORD, DATA_VHDX and
#   DATA_DISTRO are recognised only to keep their line valid and are never
#   assigned or exposed. No command substitution runs from any key.
#   No Windows interop, no formatting, no detaching, no remounting.
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

# ---------------------------------------------------------------------------
# Config file checks (contract order): missing/unreadable -> skip (3);
# symlink / non-regular / wrong owner-group / wrong mode -> invalid (4).
# Only the six-key file the Windows installer writes may be read, and it is
# never sourced. The owner check uses AGENT_DEVBOX_CONF_UID/GID so a non-root
# test runner can simulate the root-owned file; the 0600 mode is not
# overridable.
# ---------------------------------------------------------------------------
if [ -L "$CONF" ]; then
  warn "警告：会话挂载配置是符号链接（$CONF），拒绝读取。"
  exit 4
fi

if [ ! -e "$CONF" ] || [ ! -r "$CONF" ]; then
  exit 3
fi

if [ ! -f "$CONF" ]; then
  warn "警告：会话挂载配置不是普通文件（$CONF），拒绝读取。"
  exit 4
fi

EXPECT_CONF_UID="${AGENT_DEVBOX_CONF_UID:-0}"
EXPECT_CONF_GID="${AGENT_DEVBOX_CONF_GID:-0}"
conf_stat="$(stat -c '%u %g %a' "$CONF" 2>/dev/null || true)"
conf_uid=""
conf_gid=""
conf_mode=""
if [ -n "$conf_stat" ]; then
  read -r conf_uid conf_gid conf_mode <<< "$conf_stat"
fi
if [ "$conf_uid" != "$EXPECT_CONF_UID" ] || [ "$conf_gid" != "$EXPECT_CONF_GID" ]; then
  warn "警告：会话挂载配置所有者不是预期用户（$CONF）。"
  exit 4
fi
case "$conf_mode" in
  600|0600) ;;
  *)
    warn "警告：会话挂载配置权限不是 0600（$CONF）。"
    exit 4
    ;;
esac

# ---------------------------------------------------------------------------
# Strict conf reader: NO source, NO eval, NO command substitution.
#
# The installer writes Quote-Bash single-quoted values (a `'` around the value,
# an embedded quote as `'\''`); older images may have bare values and the tests
# use simple double-quoted ones. Only DATA_UUID / DATA_LABEL / DATA_MNTNAME are
# kept; PASEO_PASSWORD / DATA_VHDX / DATA_DISTRO have their line validated but
# are never assigned, so the daemon password never enters this process.
# ---------------------------------------------------------------------------
DATA_UUID=""
DATA_LABEL=""
DATA_MNTNAME=""
CONF_VALUE=""

# valid_conf_token: the six-key file only ever carries these characters for the
# keys this helper consumes. Anything else (space, ;, $, backtick, quotes,
# slashes, ...) fails closed.
valid_conf_token() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# parse_conf_value <raw>: decode one value without executing anything and store
# it in CONF_VALUE. Returns 1 on malformed/unterminated quoting or on trailing
# garbage after a closing quote.
parse_conf_value() {
  local raw="$1" out="" i=0 len c n
  len=${#raw}
  if [ "$len" -eq 0 ]; then
    CONF_VALUE=""
    return 0
  fi
  c="${raw:0:1}"
  case "$c" in
    "'")
      i=1
      while [ "$i" -lt "$len" ]; do
        c="${raw:i:1}"
        if [ "$c" = "'" ]; then
          if [ "${raw:i+1:1}" = "\\" ] && [ "${raw:i+2:1}" = "'" ] && [ "${raw:i+3:1}" = "'" ]; then
            out+="'"
            i=$((i + 4))
            continue
          fi
          if [ "$((i + 1))" -ne "$len" ]; then
            return 1
          fi
          CONF_VALUE="$out"
          return 0
        fi
        out+="$c"
        i=$((i + 1))
      done
      return 1
      ;;
    '"')
      i=1
      while [ "$i" -lt "$len" ]; do
        c="${raw:i:1}"
        if [ "$c" = "\\" ]; then
          n="${raw:i+1:1}"
          case "$n" in
            '"') out+='"' ;;
            "\\") out+="\\" ;;
            '$') out+='$' ;;
            '`') out+='`' ;;
            *) out+="\\$n" ;;
          esac
          i=$((i + 2))
          continue
        fi
        if [ "$c" = '"' ]; then
          if [ "$((i + 1))" -ne "$len" ]; then
            return 1
          fi
          CONF_VALUE="$out"
          return 0
        fi
        case "$c" in
          '$'|'`') return 1 ;;
        esac
        out+="$c"
        i=$((i + 1))
      done
      return 1
      ;;
    "\\")
      return 1
      ;;
    *)
      case "$raw" in
        *[\'\"\\]*) return 1 ;;
      esac
      CONF_VALUE="$raw"
      return 0
      ;;
  esac
}

# parse_conf_file <file>: line-by-line allowlist. Blank lines and `#` comments
# are ignored; only the six installer keys are accepted; duplicates and any
# other line fail closed. Values are parsed for every key but retained only for
# the three this helper uses.
parse_conf_file() {
  local file="$1" line key raw
  local have_uuid=0 have_label=0 have_mntname=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == *[[:cntrl:]]* ]]; then
      return 1
    fi
    if [ -z "$line" ]; then
      continue
    fi
    case "$line" in
      '#'*) continue ;;
    esac
    case "$line" in
      [A-Z_]*=*) ;;
      *) return 1 ;;
    esac
    key="${line%%=*}"
    raw="${line#*=}"
    case "$key" in
      DATA_UUID|DATA_LABEL|DATA_MNTNAME|DATA_VHDX|PASEO_PASSWORD|DATA_DISTRO) ;;
      *) return 1 ;;
    esac
    case "$key" in
      DATA_UUID)
        [ "$have_uuid" -eq 0 ] || return 1
        parse_conf_value "$raw" || return 1
        DATA_UUID="$CONF_VALUE"
        have_uuid=1
        ;;
      DATA_LABEL)
        [ "$have_label" -eq 0 ] || return 1
        parse_conf_value "$raw" || return 1
        DATA_LABEL="$CONF_VALUE"
        have_label=1
        ;;
      DATA_MNTNAME)
        [ "$have_mntname" -eq 0 ] || return 1
        parse_conf_value "$raw" || return 1
        DATA_MNTNAME="$CONF_VALUE"
        have_mntname=1
        ;;
      *)
        parse_conf_value "$raw" || return 1
        CONF_VALUE=""
        ;;
    esac
  done < "$file"
  # A missing key keeps its default; a present-but-empty used key fails closed.
  if [ "$have_uuid" -eq 1 ] && ! valid_conf_token "$DATA_UUID"; then
    return 1
  fi
  if [ "$have_label" -eq 1 ] && ! valid_conf_token "$DATA_LABEL"; then
    return 1
  fi
  if [ "$have_mntname" -eq 1 ] && ! valid_conf_token "$DATA_MNTNAME"; then
    return 1
  fi
  return 0
}

if ! parse_conf_file "$CONF"; then
  warn "警告：会话挂载配置内容无效（$CONF），本次会话不挂载。"
  exit 4
fi

# Defense in depth: the daemon password is never parsed, and must never linger.
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
  warn "警告：持久数据盘未附加；本次会话的 /home /root /workspace 仍在系统盘。修复：cmd.exe /c \"<安装目录>\\mount-datadisk.cmd\" 后重开终端，或稍后在 Windows 侧运行 wsl --terminate <发行版>。"
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
