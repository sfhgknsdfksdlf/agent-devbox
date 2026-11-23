#!/usr/bin/env bash
# Prune older beta prereleases from the GitHub Releases API.
#
# The API is read page-by-page and ALL pages are collected/validated BEFORE the
# first deletion. An API/JSON/tag error therefore leaves every release intact.
# Only non-draft `beta-*` prereleases strictly older than the current run are
# deleted; stable releases, drafts, the current release and newer runs survive.
# Pagination is bounded by --max-pages so a broken/looping API cannot run away.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
tags_helper="$script_dir/release-tags.sh"

repo=""
current=""
channel=""
max_pages=100
max_attempts=3

usage() {
  cat >&2 <<'EOF'
usage: prune-releases.sh --repo <owner/repo> --current <release_tag>
                         --channel <stable|beta>
                         [--max-pages <n>] [--max-attempts <n>]
EOF
  exit 2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ]
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --current) current="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    --max-pages) max_pages="$2"; shift 2 ;;
    --max-attempts) max_attempts="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$repo" ] || usage
[ -n "$current" ] || usage
[ -n "$channel" ] || usage
case "$channel" in
  stable|beta) ;;
  *) die "--channel must be stable or beta (got '$channel')" ;;
esac
if [ "$channel" != "beta" ]; then
  echo "not a beta channel; skip prune"
  exit 0
fi

is_positive_int "$max_pages" || die "--max-pages must be a positive integer"
is_positive_int "$max_attempts" || die "--max-attempts must be a positive integer"
[ -r "$tags_helper" ] || die "missing release-tags.sh: $tags_helper"

case "$current" in
  beta-*) ;;
  *) die "current release is not a beta tag: $current" ;;
esac
set +e
"$tags_helper" is-newer --candidate "$current" --latest "$current" --allow-equal >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || die "invalid current release tag: $current"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/releases.tsv"

# Phase 1: collect every page. A failure here (or in JSON parsing) aborts before
# any delete call. The page cap is checked before fetching the next page.
page=1
while :; do
  if [ "$page" -gt "$max_pages" ]; then
    die "release pagination exceeds --max-pages=$max_pages; refusing to prune"
  fi
  if ! body="$(gh api "repos/$repo/releases?per_page=100&page=$page")"; then
    die "failed to list releases page $page"
  fi
  if ! count="$(jq 'length' <<<"$body" 2>/dev/null)"; then
    die "invalid JSON from releases page $page"
  fi
  is_positive_int "$count" 2>/dev/null || [ "$count" = "0" ] || die "invalid release count on page $page: $count"
  if [ "$count" -gt 100 ]; then
    die "releases page $page returned $count entries (per_page=100)"
  fi
  if ! jq -r '
    .[] |
    if ((.tag_name | type) != "string"
        or (.prerelease | type) != "boolean"
        or (.draft | type) != "boolean") then
      error("release entry lacks tag_name/prerelease/draft")
    else
      [.tag_name, (.prerelease | tostring), (.draft | tostring)] | @tsv
    end
  ' <<<"$body" >> "$tmp/releases.tsv"; then
    die "invalid release entry on page $page"
  fi
  [ "$count" -lt 100 ] && break
  page=$((page + 1))
done

# Phase 2: validate/order every beta prerelease tag before deleting anything.
: > "$tmp/beta.txt"
while IFS=$'\t' read -r tag prerelease draft; do
  [ -n "$tag" ] || die "empty release tag in API response"
  case "$tag" in
    beta-*) ;;
    *) continue ;;
  esac
  [ "$prerelease" = "true" ] || continue
  [ "$draft" = "false" ] || continue
  set +e
  "$tags_helper" is-newer --candidate "$tag" --latest "$tag" --allow-equal >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || die "invalid beta release tag: $tag"
  printf '%s\n' "$tag" >> "$tmp/beta.txt"
done < "$tmp/releases.tsv"

if [ ! -s "$tmp/beta.txt" ]; then
  echo "no beta prereleases; skip prune"
  exit 0
fi
LC_ALL=C sort -u "$tmp/beta.txt" -o "$tmp/beta.txt"

# The current release must be visible before we can order it. If the API is
# lagging, skip rather than risk deleting the actual newest beta.
if ! grep -Fxq "$current" "$tmp/beta.txt"; then
  echo "current release $current is not visible yet; skip prune"
  exit 0
fi

latest="$("$tags_helper" newest < "$tmp/beta.txt")"
[ -n "$latest" ] || die "cannot determine the newest beta release"

# Anti-regression: an older run/attempt must never prune a newer one.
set +e
"$tags_helper" is-newer --candidate "$current" --latest "$latest" --allow-equal
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  echo "older run ($current < $latest); skip prune"
  exit 0
fi
[ "$rc" -eq 0 ] || die "cannot compare $current with $latest"

# Build the delete list last, after every input has been validated.
: > "$tmp/delete.txt"
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  [ "$tag" = "$current" ] && continue
  set +e
  "$tags_helper" is-newer --candidate "$tag" --latest "$current"
  rc=$?
  set -e
  case "$rc" in
    0) echo "keep newer release: $tag" ;;
    1) printf '%s\n' "$tag" >> "$tmp/delete.txt" ;;
    *) die "cannot compare $tag with $current" ;;
  esac
done < "$tmp/beta.txt"

# Phase 3: delete bounded candidates with per-release retries.
failed=0
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  attempt=1
  ok=0
  while [ "$attempt" -le "$max_attempts" ]; do
    echo "deleting old beta release: $tag (attempt $attempt/$max_attempts)"
    if gh release delete "$tag" --yes --cleanup-tag; then
      ok=1
      break
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$max_attempts" ]; then
      sleep 1
    fi
  done
  if [ "$ok" -ne 1 ]; then
    echo "ERROR: failed to prune $tag after $max_attempts attempt(s)" >&2
    failed=1
  fi
done < "$tmp/delete.txt"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "prune complete"
