#!/usr/bin/env bash
# image-assets — enforce the verified third-party build-asset policy (P1-1).
#
# Every archive/binary the Dockerfiles download must have an exact
# (version, filename, arch) -> sha256 row in config/image-assets.sha256, and the
# build must verify the downloaded bytes BEFORE extracting or installing them.
# This script is the single implementation of that policy: it is COPYed into the
# image as /usr/local/bin/image-assets and is exercised directly by
# tests/bats/image-pins.bats.
#
# Commands:
#   verify-manifest <file>
#       Validate the TSV: exact header, 4 non-empty tab-separated columns,
#       lower-case 64-hex sha256, arch in {amd64,arm64}, unique
#       (version, filename, arch). Prints the entry count.
#   verify-file <file> <version> <filename> <arch> <path>
#       Require the exact row and compare the file's sha256 with it. Read-only:
#       the target is never modified. Non-zero on any mismatch.
#   update-go <file> <version> <amd64-sha256> <arm64-sha256>
#       Replace the Go linux tarball rows in one atomic write (temp file in the
#       same directory + mv). uv/marksman/PowerShell rows are preserved verbatim.
#       The generated file is re-validated before it replaces the manifest.
#   asset-name <kind> <arch> [version]
#       Print the exact upstream filename for kind {marksman,uv,go,powershell}.
#       Unknown architectures are fatal (never an amd64 fallback).
#   sha-from-sums <sums-file> <basename>
#       Extract exactly one sha256 from a sha256sum-style file (e.g. the
#       PowerShell hashes.sha256 after UTF-16 -> UTF-8 decoding).
#
# asset-name and sha-from-sums keep the arch mapping and the sums parsing in one
# tested implementation instead of duplicating them as unverifiable text inside
# the Dockerfiles.
set -euo pipefail

readonly PROG="${0##*/}"
readonly MANIFEST_HEADER=$'version\tfilename\tarch\tsha256'
readonly SHA256_RE='^[0-9a-f]{64}$'
readonly TOKEN_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

# Temp path for update-go, cleaned up by the EXIT trap even when it dies.
UPDATE_TMP=""

usage() {
  cat <<'EOF'
usage: image-assets <command> [args]

  verify-manifest <file>
  verify-file <file> <version> <filename> <arch> <path>
  update-go <file> <version> <amd64-sha256> <arm64-sha256>
  asset-name <kind> <arch> [version]
  sha-from-sums <sums-file> <basename>
EOF
}

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

cleanup_update_tmp() {
  if [ -n "${UPDATE_TMP:-}" ]; then
    rm -f -- "$UPDATE_TMP"
  fi
}

# A manifest token must never be a URL, a glob, a path or blank.
require_token() {
  local label="$1"
  local value="${2:-}"
  [ -n "$value" ] || die "$label must not be empty"
  case "$value" in
    *..*|*/*|*\\*|*'*'*|*'?'*|*' '*|*$'\t'*|*$'\n'*)
      die "unsafe $label: $value" ;;
  esac
  if ! [[ "$value" =~ $TOKEN_RE ]]; then
    die "invalid $label: $value"
  fi
}

validate_arch() {
  case "${1:-}" in
    amd64|arm64) ;;
    *) die "unsupported architecture: ${1:-} (expected amd64 or arm64; no fallback)" ;;
  esac
}

# Split one validated 4-column row on literal tabs, preserving empty fields
# (`IFS= read` would collapse consecutive tabs).
split_row() {
  local rest
  ROW_VER="${1%%$'\t'*}"
  rest="${1#*$'\t'}"
  ROW_NAME="${rest%%$'\t'*}"
  rest="${rest#*$'\t'}"
  ROW_ARCH="${rest%%$'\t'*}"
  ROW_SHA="${rest#*$'\t'}"
}

# Validate a manifest and print its data-row count.
manifest_check() {
  local file="$1"
  local line lineno=0 count=0 first=1
  local ver name arch sha key rest tabs
  local -A seen=()

  [ -f "$file" ] || die "manifest not found: $file"

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    if [ "$first" -eq 1 ]; then
      if [ "$line" != "$MANIFEST_HEADER" ]; then
        die "invalid header at $file:$lineno (expected version<TAB>filename<TAB>arch<TAB>sha256)"
      fi
      first=0
      continue
    fi

    [ -n "$line" ] || die "blank row at $file:$lineno"

    # Exactly three tabs: 4 columns, no trailing column.
    rest="$line"
    tabs=0
    while [[ "$rest" == *$'\t'* ]]; do
      rest="${rest#*$'\t'}"
      tabs=$((tabs + 1))
    done
    if [ "$tabs" -ne 3 ]; then
      die "malformed row at $file:$lineno (expected 4 tab-separated columns)"
    fi

    split_row "$line"
    ver="$ROW_VER"
    name="$ROW_NAME"
    arch="$ROW_ARCH"
    sha="$ROW_SHA"

    require_token version "$ver"
    require_token filename "$name"
    validate_arch "$arch"
    if ! [[ "$sha" =~ $SHA256_RE ]]; then
      die "invalid sha256 at $file:$lineno (expected 64 lower-case hex chars)"
    fi

    key="$ver"$'\t'"$name"$'\t'"$arch"
    if [ -n "${seen[$key]:-}" ]; then
      die "duplicate (version, filename, arch) at $file:$lineno: $ver / $name / $arch"
    fi
    seen[$key]=1
    count=$((count + 1))
  done < "$file"

  [ "$first" -eq 0 ] || die "manifest has no header: $file"
  [ "$count" -gt 0 ] || die "manifest has no data rows: $file"
  printf '%s\n' "$count"
}

cmd_verify_manifest() {
  [ "$#" -eq 1 ] || die "verify-manifest: expected 1 argument (got $#)"
  local count
  count="$(manifest_check "$1")"
  printf '%s: manifest ok (%s entries)\n' "$PROG" "$count"
}

cmd_verify_file() {
  [ "$#" -eq 5 ] || die "verify-file: expected 5 arguments (got $#)"
  local file="$1" version="$2" filename="$3" arch="$4" path="$5"
  local line ver name entry_arch sha actual found=""

  require_token version "$version"
  require_token filename "$filename"
  validate_arch "$arch"

  # Validate the whole manifest first: a malformed file must fail closed even
  # when the one requested row happens to look fine.
  manifest_check "$file" >/dev/null

  while IFS= read -r line; do
    if [ "$line" = "$MANIFEST_HEADER" ]; then
      continue
    fi
    split_row "$line"
    ver="$ROW_VER"
    name="$ROW_NAME"
    entry_arch="$ROW_ARCH"
    sha="$ROW_SHA"
    if [ "$ver" = "$version" ] && [ "$name" = "$filename" ] && [ "$entry_arch" = "$arch" ]; then
      found="$sha"
      break
    fi
  done < "$file"

  [ -n "$found" ] || die "no manifest entry for version=$version filename=$filename arch=$arch"
  [ -f "$path" ] || die "file not found: $path"

  if ! actual="$(sha256sum -- "$path")"; then
    die "cannot hash $path"
  fi
  actual="${actual%% *}"

  if [ "$actual" != "$found" ]; then
    die "sha256 mismatch for $filename ($arch): expected $found, got $actual"
  fi
  printf '%s: verified %s (%s, %s)\n' "$PROG" "$filename" "$arch" "$version"
}

cmd_update_go() {
  [ "$#" -eq 4 ] || die "update-go: expected 4 arguments (got $#)"
  local file="$1" version="$2" amd64_sha="$3" arm64_sha="$4"
  local amd64_file arm64_file line ver name arch sha checks
  local emitted_amd64=0 emitted_arm64=0
  local n_amd n_arm n_go new_count

  require_token version "$version"
  if ! [[ "$amd64_sha" =~ $SHA256_RE ]]; then
    die "invalid amd64 sha256: $amd64_sha"
  fi
  if ! [[ "$arm64_sha" =~ $SHA256_RE ]]; then
    die "invalid arm64 sha256: $arm64_sha"
  fi
  amd64_file="go${version}.linux-amd64.tar.gz"
  arm64_file="go${version}.linux-arm64.tar.gz"
  require_token filename "$amd64_file"
  require_token filename "$arm64_file"

  manifest_check "$file" >/dev/null

  # Temp file in the target directory so the final mv is an atomic rename.
  UPDATE_TMP="$(mktemp "$(dirname -- "$file")/.image-assets.XXXXXX")"
  trap cleanup_update_tmp EXIT

  {
    printf '%s\n' "$MANIFEST_HEADER"
    while IFS= read -r line; do
      if [ "$line" = "$MANIFEST_HEADER" ]; then
        continue
      fi
      split_row "$line"
      ver="$ROW_VER"
      name="$ROW_NAME"
      arch="$ROW_ARCH"
      sha="$ROW_SHA"
      case "$name" in
        go*.linux-amd64.tar.gz)
          if [ "$emitted_amd64" -eq 0 ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "$amd64_file" amd64 "$amd64_sha"
            emitted_amd64=1
          fi
          continue
          ;;
        go*.linux-arm64.tar.gz)
          if [ "$emitted_arm64" -eq 0 ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "$arm64_file" arm64 "$arm64_sha"
            emitted_arm64=1
          fi
          continue
          ;;
      esac
      printf '%s\n' "$line"
    done < "$file"
    if [ "$emitted_amd64" -eq 0 ]; then
      printf '%s\t%s\t%s\t%s\n' "$version" "$amd64_file" amd64 "$amd64_sha"
    fi
    if [ "$emitted_arm64" -eq 0 ]; then
      printf '%s\t%s\t%s\t%s\n' "$version" "$arm64_file" arm64 "$arm64_sha"
    fi
  } > "$UPDATE_TMP"

  new_count="$(manifest_check "$UPDATE_TMP")"
  checks="$(awk -F'\t' -v v="$version" -v af="$amd64_file" -v rf="$arm64_file" '
    NR == 1 { next }
    $1 == v && $2 == af && $3 == "amd64" { amd++ }
    $1 == v && $2 == rf && $3 == "arm64" { arm++ }
    $2 ~ /^go.*\.linux-(amd64|arm64)\.tar\.gz$/ { go++ }
    END { print amd + 0, arm + 0, go + 0 }
  ' "$UPDATE_TMP")"
  read -r n_amd n_arm n_go <<< "$checks"

  if [ "$n_amd" -ne 1 ] || [ "$n_arm" -ne 1 ] || [ "$n_go" -ne 2 ]; then
    die "update-go: generated manifest is inconsistent (amd64=$n_amd arm64=$n_arm go=$n_go)"
  fi

  if [ -e "$file" ]; then
    chmod --reference="$file" "$UPDATE_TMP" 2>/dev/null || chmod 0644 "$UPDATE_TMP"
  else
    chmod 0644 "$UPDATE_TMP"
  fi
  mv -f -- "$UPDATE_TMP" "$file"
  UPDATE_TMP=""
  printf '%s: updated Go rows to %s (%s entries)\n' "$PROG" "$version" "$new_count"
}

cmd_asset_name() {
  [ "$#" -ge 2 ] || die "asset-name: expected at least 2 arguments (got $#)"
  local kind="$1" arch="$2" version="${3:-}"

  validate_arch "$arch"

  case "$kind" in
    marksman)
      [ "$#" -eq 2 ] || die "asset-name marksman: unexpected extra arguments"
      case "$arch" in
        amd64) printf '%s\n' 'marksman-linux-x64' ;;
        arm64) printf '%s\n' 'marksman-linux-arm64' ;;
      esac
      ;;
    uv)
      [ "$#" -eq 2 ] || die "asset-name uv: unexpected extra arguments"
      case "$arch" in
        amd64) printf '%s\n' 'uv-x86_64-unknown-linux-gnu.tar.gz' ;;
        arm64) printf '%s\n' 'uv-aarch64-unknown-linux-gnu.tar.gz' ;;
      esac
      ;;
    go)
      [ "$#" -eq 2 ] || die "asset-name go: unexpected extra arguments"
      printf '%s\n' "$arch"
      ;;
    powershell)
      [ "$#" -eq 3 ] || die "asset-name powershell: expected <arch> <version>"
      require_token version "$version"
      printf 'powershell_%s-1.deb_%s.deb\n' "$version" "$arch"
      ;;
    *)
      die "unknown asset kind: $kind (marksman|uv|go|powershell)"
      ;;
  esac
}

cmd_sha_from_sums() {
  [ "$#" -eq 2 ] || die "sha-from-sums: expected 2 arguments (got $#)"
  local sums="$1" base="$2" line hash name count=0 found=""

  [ -f "$sums" ] || die "sums file not found: $sums"
  require_token basename "$base"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    hash="${line%%[[:space:]]*}"
    name="${line#"$hash"}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name#\*}"
    [ "$name" = "$base" ] || continue
    if ! [[ "$hash" =~ $SHA256_RE ]]; then
      die "malformed sha256 for $base in $sums"
    fi
    found="$hash"
    count=$((count + 1))
  done < "$sums"

  [ "$count" -eq 1 ] || die "expected exactly one entry for $base in $sums (found $count)"
  printf '%s\n' "$found"
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local cmd="$1"
  shift

  case "$cmd" in
    verify-manifest) cmd_verify_manifest "$@" ;;
    verify-file) cmd_verify_file "$@" ;;
    update-go) cmd_update_go "$@" ;;
    asset-name) cmd_asset_name "$@" ;;
    sha-from-sums) cmd_sha_from_sums "$@" ;;
    -h|--help|help) usage ;;
    *)
      printf '%s: unknown command: %s\n' "$PROG" "$cmd" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
