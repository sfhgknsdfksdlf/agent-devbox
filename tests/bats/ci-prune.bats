#!/usr/bin/env bats
# P2-D3: hermetic tests for .github/scripts/prune-releases.sh.
#
# A fake `gh` serves paginated Releases API responses and records every delete.
# The real .github/scripts/release-tags.sh is used for ordering/validation.
# No network, no real GitHub calls.

setup() {
  TMP="$(mktemp -d)"
  export TMP
  export PRUNE="$BATS_TEST_DIRNAME/../../.github/scripts/prune-releases.sh"
  export FAKE_RELEASES="$TMP/releases.json"
  export FAKE_GH_LOG="$TMP/gh.log"
  export FAKE_DELETE_LOG="$TMP/delete.log"
  : > "$FAKE_GH_LOG"
  : > "$FAKE_DELETE_LOG"

  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"

case "${1:-}" in
  api)
    shift
    url="${1:-}"
    case "$url" in
      repos/*/releases?per_page=100\&page=*) page="${url##*page=}" ;;
      *) echo "unexpected api URL: $url" >&2; exit 2 ;;
    esac
    if [ -n "${FAKE_FAIL_PAGE:-}" ] && [ "$page" = "$FAKE_FAIL_PAGE" ]; then
      echo "injected API failure on page $page" >&2
      exit 1
    fi
    jq --argjson p "$page" '.[(($p - 1) * 100):($p * 100)]' "$FAKE_RELEASES"
    ;;
  release)
    [ "${2:-}" = "delete" ] || { echo "unexpected release command" >&2; exit 2; }
    tag="${3:-}"
    printf '%s\n' "$tag" >> "$FAKE_DELETE_LOG"
    if [ -n "${FAKE_DELETE_FAIL_ONCE:-}" ] && [ "$tag" = "$FAKE_DELETE_FAIL_ONCE" ]; then
      marker="$TMP/failed-once-${tag//\//_}"
      if [ ! -e "$marker" ]; then
        : > "$marker"
        exit 1
      fi
    fi
    if [ -n "${FAKE_DELETE_FAIL_ALWAYS:-}" ] && [ "$tag" = "$FAKE_DELETE_FAIL_ALWAYS" ]; then
      exit 1
    fi
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 2
    ;;
esac
GH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TMP"
}

# make_releases <old-beta-count> <current-run> [extra-tag]
# Layout: stable, beta draft, current, N old betas, optional extra beta.
make_releases() {
  python3 - "$FAKE_RELEASES" "$1" "$2" "${3:-}" <<'PY'
import json
import sys

out, count, current, extra = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
releases = [
    {"tag_name": "build-20261123.0000-2000.1", "prerelease": False, "draft": False},
    {"tag_name": "beta-20261123.0000-1999.1", "prerelease": True, "draft": True},
    {"tag_name": f"beta-20261123.0000-{current}.1", "prerelease": True, "draft": False},
]
for i in range(1, count + 1):
    releases.append({"tag_name": f"beta-20261123.0000-{i}.1", "prerelease": True, "draft": False})
if extra:
    releases.append({"tag_name": extra, "prerelease": True, "draft": False})
with open(out, "w", encoding="utf-8") as fh:
    json.dump(releases, fh)
PY
}

run_prune() {
  run "$PRUNE" --repo testowner/agent-devbox --current "$CURRENT" --channel beta "$@"
}

@test "prune: collects all pages and deletes only old beta prereleases" {
  make_releases 120 999
  CURRENT="beta-20261123.0000-999.1"
  run_prune
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$FAKE_DELETE_LOG")" -eq 120 ]
  grep -qx 'beta-20261123.0000-1.1' "$FAKE_DELETE_LOG"
  grep -qx 'beta-20261123.0000-120.1' "$FAKE_DELETE_LOG"
  ! grep -q '^build-' "$FAKE_DELETE_LOG"
  ! grep -q 'beta-20261123.0000-1999.1' "$FAKE_DELETE_LOG"
  ! grep -q 'beta-20261123.0000-999.1' "$FAKE_DELETE_LOG"
}

@test "prune: an older current run never deletes a newer beta" {
  make_releases 120 50
  CURRENT="beta-20261123.0000-50.1"
  run_prune
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_DELETE_LOG" ]
}

@test "prune: an invalid beta tag on page 2 aborts before any delete" {
  make_releases 120 999 beta-not-a-tag
  CURRENT="beta-20261123.0000-999.1"
  run_prune
  [ "$status" -ne 0 ]
  [ ! -s "$FAKE_DELETE_LOG" ]
}

@test "prune: a page-2 API failure aborts before any delete" {
  make_releases 120 999
  CURRENT="beta-20261123.0000-999.1"
  export FAKE_FAIL_PAGE=2
  run_prune
  [ "$status" -ne 0 ]
  [ ! -s "$FAKE_DELETE_LOG" ]
}

@test "prune: --max-pages bounds pagination before any delete" {
  make_releases 120 999
  CURRENT="beta-20261123.0000-999.1"
  run_prune --max-pages 1
  [ "$status" -ne 0 ]
  [ ! -s "$FAKE_DELETE_LOG" ]
}

@test "prune: a transient delete failure is retried" {
  make_releases 3 999
  CURRENT="beta-20261123.0000-999.1"
  export FAKE_DELETE_FAIL_ONCE="beta-20261123.0000-1.1"
  run_prune
  [ "$status" -eq 0 ]
  [ "$(grep -c '^beta-20261123\.0000-1\.1$' "$FAKE_DELETE_LOG")" -eq 2 ]
}

@test "prune: a permanent delete failure exits non-zero after bounded retries" {
  make_releases 3 999
  CURRENT="beta-20261123.0000-999.1"
  export FAKE_DELETE_FAIL_ALWAYS="beta-20261123.0000-2.1"
  run_prune --max-attempts 2
  [ "$status" -ne 0 ]
  [ "$(grep -c '^beta-20261123\.0000-2\.1$' "$FAKE_DELETE_LOG")" -eq 2 ]
  grep -qx 'beta-20261123.0000-1.1' "$FAKE_DELETE_LOG"
  grep -qx 'beta-20261123.0000-3.1' "$FAKE_DELETE_LOG"
  ! grep -q '^build-' "$FAKE_DELETE_LOG"
  ! grep -q 'beta-20261123.0000-1999.1' "$FAKE_DELETE_LOG"
}
