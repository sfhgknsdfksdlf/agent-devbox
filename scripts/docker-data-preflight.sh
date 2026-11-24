#!/usr/bin/env bash
# =============================================================================
# docker-data-preflight.sh — Docker-mode data-disk identity preflight.
#
# Docker mounts the WHOLE home tree from the host's DATA_DIR:
#   ${DATA_DIR}/home    -> /home
#   ${DATA_DIR}/root    -> /root
#   ${DATA_DIR}/project -> /workspace
# and mounts ${DATA_DIR} read-only at /run/agent-devbox/data as the identity
# baseline. Before ANY seed, chown or service start this script proves:
#
#   1. /run/agent-devbox/data exists and is a real mountpoint;
#   2. every target shares the identity of its baseline subdirectory
#      (`stat -c '%d:%i'`):
#        /run/agent-devbox/data/home    <-> /home
#        /run/agent-devbox/data/root    <-> /root
#        /run/agent-devbox/data/project <-> /workspace
#
# A missing or mismatched bind is FATAL: writing into the container's ephemeral
# layer would silently lose user data, so the container refuses to start.
#
# Only after those checks pass does the empty-HOME first run initialize:
#   * /home/paseo owned 1000:1000 (the paseo daemon's HOME);
#   * /root owned 0:0 mode 0700 (never weakened);
#   * /workspace present;
#   * MISSING skeleton files seeded from /etc/skel and /opt/agent-seed (existing
#     files are never overwritten);
#   * /root/.opencode/bin/opencode (and the paseo home probe link) recreated via
#     the existing ensure_opencode_shim logic from wsl-boot.sh.
# Ownership changes are per-directory only — never a recursive chown.
#
# Docker mode only: IS_DOCKER != true is a silent no-op, so WSL (which calls
# paseo-boot.sh directly) never runs this. wsl-boot.sh must not source it.
# =============================================================================
set -euo pipefail

if [ "${IS_DOCKER:-false}" != "true" ]; then
  exit 0
fi

# Reuse the canonical desktop-OpenCode probe-link logic from wsl-boot.sh. That
# file is explicitly safe to source (all side effects sit behind its
# BASH_SOURCE guard); re-pin our shell options afterwards because it
# deliberately runs without `-e`.
case "${BASH_SOURCE[0]}" in
  */*) _preflight_dir="${BASH_SOURCE[0]%/*}" ;;
  *) _preflight_dir="." ;;
esac
if [ ! -f "$_preflight_dir/wsl-boot.sh" ]; then
  echo "FATAL: missing $_preflight_dir/wsl-boot.sh (ensure_opencode_shim); refusing to start." >&2
  exit 1
fi
# shellcheck source=scripts/wsl-boot.sh
# shellcheck disable=SC1091
. "$_preflight_dir/wsl-boot.sh"
set -euo pipefail

# ensure_opencode_shim logs through `log`; retag its lines for the Docker path.
log() {
  printf '[docker-data-preflight %s] %s\n' "$(date -Is)" "$*"
}

DATA_ROOT="${AGENT_DEVBOX_DATA_ROOT:-/run/agent-devbox/data}"
HOME_DIR="${AGENT_DEVBOX_HOME_DIR:-/home}"
ROOT_DIR="${AGENT_DEVBOX_ROOT_DIR:-/root}"
WORKSPACE_DIR="${AGENT_DEVBOX_WORKSPACE_DIR:-/workspace}"
PASEO_UID="${AGENT_DEVBOX_PASEO_UID:-1000}"
PASEO_GID="${AGENT_DEVBOX_PASEO_GID:-1000}"
SEED_DIR="${AGENT_SEED_DIR:-/opt/agent-seed}"
SKEL_DIR="${AGENT_DEVBOX_SKEL_DIR:-/etc/skel}"
STAT_BIN="${AGENT_DEVBOX_STAT_BIN:-$(command -v stat 2>/dev/null || true)}"
CHOWN_BIN="${AGENT_DEVBOX_CHOWN_BIN:-$(command -v chown 2>/dev/null || true)}"
FINDMNT_BIN="${AGENT_DEVBOX_FINDMNT_BIN:-$(command -v findmnt 2>/dev/null || true)}"
# `-` (not `:-`) so an explicitly empty value disables the user switch (tests).
GOSU_BIN="${AGENT_DEVBOX_GOSU_BIN-$(command -v gosu 2>/dev/null || true)}"

fail() {
  printf 'FATAL: %s\n' "$*" >&2
  exit 1
}

identity_of() {
  "$STAT_BIN" -c '%d:%i' -- "$1"
}

# check_identity <label> <baseline-dir> <target-dir>: the target must resolve to
# the very same directory the DATA_DIR baseline exposes.
check_identity() {
  local label="$1" base="$2" target="$3" want got
  if [ ! -d "$base" ]; then
    fail "数据盘基准子目录缺失 / baseline subdirectory missing: $base ($label). The DATA_DIR bind is incomplete; refusing to seed or start."
  fi
  if [ ! -d "$target" ]; then
    fail "挂载目标缺失 / target missing: $target ($label). Create the matching DATA_DIR subdirectory and mount it; refusing to seed or start."
  fi
  if ! want="$(identity_of "$base")"; then
    fail "无法读取身份 / cannot stat: $base ($label)."
  fi
  if ! got="$(identity_of "$target")"; then
    fail "无法读取身份 / cannot stat: $target ($label)."
  fi
  if [ "$want" != "$got" ]; then
    fail "数据盘身份不匹配 / data-disk identity mismatch: $label target=$target expected=$want (from $base) actual=$got. The bind points somewhere else; refusing to seed or start."
  fi
  printf '%s identity ok: %s == %s (%s)\n' "$label" "$base" "$target" "$want"
}

# ensure_owned <path> <uid:gid> <label>: chown ONLY this path (never recurse),
# then re-stat and require the exact numeric owner.
ensure_owned() {
  local path="$1" want="$2" label="$3" current
  if ! current="$("$STAT_BIN" -c '%u:%g' -- "$path")"; then
    fail "无法读取属主 / cannot read owner: $path ($label)."
  fi
  if [ "$current" = "$want" ]; then
    return 0
  fi
  if ! "$CHOWN_BIN" "$want" -- "$path"; then
    fail "无法设置属主 / cannot chown $path to $want ($label)."
  fi
  if ! current="$("$STAT_BIN" -c '%u:%g' -- "$path")"; then
    fail "无法复核属主 / cannot re-check owner: $path ($label, expected $want)."
  fi
  if [ "$current" != "$want" ]; then
    fail "属主复核失败 / owner mismatch: $path expected=$want actual=$current ($label)."
  fi
  printf 'chowned %s %s to %s\n' "$label" "$path" "$want"
}

# run_as_paseo: write seeded files as the paseo user so they are owned correctly
# without any recursive chown. Without gosu (tests) run directly.
run_as_paseo() {
  if [ -n "$GOSU_BIN" ]; then
    "$GOSU_BIN" paseo "$@"
    return
  fi
  "$@"
}

# seed_missing_tree <src> <dest> <label>: copy only entries that do not exist
# yet (`--update=none`), never overwriting user data. `cp -R` (not `-a`) keeps
# the destination directory's own owner/mode intact; run as paseo so new files
# are owned by paseo without any recursive chown.
seed_missing_tree() {
  local src="$1" dest="$2" label="$3"
  [ -d "$src" ] || return 0
  if ! run_as_paseo cp -R --update=none -- "$src/." "$dest/"; then
    printf 'WARN: could not seed %s from %s (existing files were not touched)\n' "$label" "$src" >&2
  fi
}

# ---------------------------------------------------------------------------
# 1) Read-only baseline: must exist and be a mountpoint.
# ---------------------------------------------------------------------------
[ -n "$STAT_BIN" ] || fail "缺少 stat / stat not found; cannot verify the data-disk bind."
[ -n "$CHOWN_BIN" ] || fail "缺少 chown / chown not found; cannot repair ownership."
[ -d "$DATA_ROOT" ] || fail "数据盘基准目录不存在 / baseline bind missing: $DATA_ROOT. Mount DATA_DIR read-only at /run/agent-devbox/data; refusing to seed or start."
if [ -z "$FINDMNT_BIN" ]; then
  fail "缺少 findmnt / findmnt not found; cannot verify $DATA_ROOT is a mountpoint."
fi
if ! "$FINDMNT_BIN" -rn --mountpoint "$DATA_ROOT" >/dev/null 2>&1; then
  fail "数据盘基准不是挂载点 / baseline is not a mountpoint: $DATA_ROOT. Mount DATA_DIR read-only there; refusing to seed or start."
fi

# ---------------------------------------------------------------------------
# 2) Identity: every target must be the same directory as its baseline entry.
#    Nothing below this block may run (or write) when a check fails.
# ---------------------------------------------------------------------------
check_identity "home" "$DATA_ROOT/home" "$HOME_DIR"
check_identity "root" "$DATA_ROOT/root" "$ROOT_DIR"
check_identity "workspace" "$DATA_ROOT/project" "$WORKSPACE_DIR"

# ---------------------------------------------------------------------------
# 3) First-run initialization (only after identity is proven).
# ---------------------------------------------------------------------------
PASEO_HOME_DIR="$HOME_DIR/paseo"
first_run=0
if [ ! -d "$PASEO_HOME_DIR" ]; then
  first_run=1
elif [ -z "$(find "$PASEO_HOME_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  first_run=1
fi
mkdir -p -- "$HOME_DIR" "$PASEO_HOME_DIR" "$ROOT_DIR" "$WORKSPACE_DIR"
ensure_owned "$PASEO_HOME_DIR" "$PASEO_UID:$PASEO_GID" "paseo home"
ensure_owned "$ROOT_DIR" "0:0" "root home"
if ! chmod 0700 -- "$ROOT_DIR"; then
  fail "无法设置 /root 权限 / cannot set mode 0700 on $ROOT_DIR."
fi

if [ "$first_run" -eq 1 ]; then
  seed_missing_tree "$SKEL_DIR" "$PASEO_HOME_DIR" "skeleton"
fi
# Seed only the same two paths as seed-agent-config.sh; /opt/agent-seed also
# carries build caches (.bun/install/cache) that must never land in $HOME.
for rel in ".config/opencode" ".omo"; do
  [ -d "$SEED_DIR/$rel" ] || continue
  run_as_paseo mkdir -p -- "$PASEO_HOME_DIR/$rel"
  seed_missing_tree "$SEED_DIR/$rel" "$PASEO_HOME_DIR/$rel" "agent seed ($rel)"
done

# Desktop OpenCode probes ONLY $HOME/.opencode/bin/opencode; /root and /home now
# live on the data disk, so recreate the links the image baked under /root.
ensure_opencode_shim "$ROOT_DIR" "$PASEO_HOME_DIR"
