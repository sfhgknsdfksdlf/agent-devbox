#!/usr/bin/env bash
# Regenerate windows/SHA256SUMS from the STAGED blobs (the exact bytes
# raw.githubusercontent.com serves). Hashing the index rather than the working
# tree keeps CRLF/autocrlf checkouts from changing the digest. Stage changes
# first: git add windows/.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for f in windows/*.ps1 windows/*.cmd; do
  rel="${f#windows/}"
  if ! git cat-file -e ":$f" 2>/dev/null; then
    echo "error: $f is not staged; git add it first" >&2
    exit 1
  fi
  hash="$(git cat-file blob ":$f" | sha256sum | cut -d' ' -f1)"
  printf '%s  %s\n' "$hash" "$rel"
done | sort -k2 > "$tmp"

mv "$tmp" windows/SHA256SUMS
trap - EXIT
cat windows/SHA256SUMS
