#!/usr/bin/env bash
# Commit an empty keepalive change to main only when main has been quiet for
# ~50 days. GitHub disables scheduled workflows after 60 days without activity.
#
# Serialisation matters: two overlapping runs must not both create a commit.
# The whole fetch/check/commit/push sequence runs under a git-dir flock. The
# workflow also uses a fixed, non-cancelling concurrency group.
set -euo pipefail

branch="main"
now=""

usage() {
  cat >&2 <<'EOF'
usage: keepalive.sh [--branch main] [--now <unix_epoch_seconds>]
EOF
  exit 2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch) branch="$2"; shift 2 ;;
    --now) now="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [ "$branch" != "main" ]; then
  echo "branch '$branch' is not main; keepalive never pushes"
  exit 0
fi

[ -n "$now" ] || now="$(date -u +%s)"
is_uint "$now" || die "--now must be Unix epoch seconds (got '$now')"
command -v flock >/dev/null 2>&1 || die "flock is required for keepalive serialisation"

git_dir="$(git rev-parse --git-dir)"
[ -n "$git_dir" ] || die "not inside a git worktree"
lock="$git_dir/keepalive.lock"
exec 9>"$lock"
if ! flock -x 9; then
  die "cannot acquire keepalive lock: $lock"
fi

git fetch --quiet origin "$branch"
git checkout --quiet -B "$branch" "origin/$branch"

last="$(git log -1 --format=%ct "$branch")"
[ -n "$last" ] || die "cannot determine the last commit on $branch"
is_uint "$last" || die "invalid last-commit timestamp on $branch: $last"

# 50 days. A clock skew (last > now) is treated as recent: never commit.
age=$((now - last))
if [ "$age" -lt 4320000 ]; then
  echo "$branch has a commit within the last 50 days; skipping keepalive"
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git commit --allow-empty -m "chore: keepalive (avoid 60-day schedule auto-disable)"
git push origin "HEAD:$branch"
echo "keepalive commit pushed to $branch"
