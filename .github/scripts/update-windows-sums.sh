#!/usr/bin/env bash
# Regenerate windows/SHA256SUMS from the STAGED blobs (the exact bytes
# raw.githubusercontent.com serves). Enumeration is index-driven
# (`git ls-files --cached`), so a staged addition is included, a staged
# deletion is dropped, and untracked worktree files are never hashed.
# Hashing the index blob rather than the worktree keeps CRLF/autocrlf
# checkouts from changing the digest. Stage changes first: git add windows/.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: $repo_root is not a git repository" >&2
  exit 1
fi

sums_dir="$repo_root/windows"
manifest="$sums_dir/SHA256SUMS"
if [ ! -d "$sums_dir" ]; then
  echo "error: $sums_dir does not exist" >&2
  exit 1
fi

# The temp file lives next to the manifest so the final mv is an atomic
# same-directory replace. The trap removes it on any failure path.
tmp=""
cleanup() {
  if [ -n "$tmp" ]; then
    rm -f "$tmp"
  fi
}
trap cleanup EXIT

tmp="$(mktemp "$sums_dir/.SHA256SUMS.tmp.XXXXXX")"

# Sort the NUL-delimited paths themselves (not the hash lines) so a space or
# newline in a name cannot split the sort key, and force byte order so the
# result does not depend on the caller's locale.
while IFS= read -r -d '' f; do
  case "$f" in
    windows/*/*) continue ;;                 # nested directories are not install scripts
    windows/.*) continue ;;                  # dotfiles are outside the windows/*.ps1 glob
    windows/*.ps1 | windows/*.cmd) ;;
    *) continue ;;
  esac

  rel="${f#windows/}"
  if ! digest="$(git cat-file blob ":$f" 2>/dev/null | sha256sum | cut -d' ' -f1)"; then
    echo "error: cannot read the staged blob for '$f'; run: git add windows/" >&2
    exit 1
  fi
  printf '%s  %s\n' "$digest" "$rel"
done < <(git ls-files --cached -z -- windows | LC_ALL=C sort -z) > "$tmp"

mv "$tmp" "$manifest"
tmp=""
trap - EXIT
cat "$manifest"
