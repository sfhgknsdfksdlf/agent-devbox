#!/usr/bin/env bash
# Validate the four per-arch build digests and merge them into exactly two
# multi-arch index digests (core, agents).
#
# Inputs (downloaded artifact directory, merge-multiple=true):
#   digest-core-amd64   digest-core-arm64
#   digest-agents-amd64 digest-agents-arm64
#
# Each file contains one `sha256:<64 hex>` value. The script creates the
# candidate tag FROM the digests (never from a mutable per-arch tag), checks
# that the resulting index contains exactly linux/amd64 + linux/arm64, and
# prints:
#   core_digest=sha256:...
#   agents_digest=sha256:...
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

dir=""
tag=""
core_image=""
agents_image=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --tag) tag="$2"; shift 2 ;;
    --core-image) core_image="$2"; shift 2 ;;
    --agents-image) agents_image="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$dir" ] || die "--dir is required"
[ -d "$dir" ] || die "digest directory does not exist: $dir"
[ -n "$tag" ] || die "--tag is required"
[ -n "$core_image" ] || die "--core-image is required"
[ -n "$agents_image" ] || die "--agents-image is required"

if [ -n "${CORE_IMAGE:-}" ] && [ "$core_image" != "${CORE_IMAGE:-}" ]; then
  die "core image mismatch"
fi
if [ -n "${AGENTS_IMAGE:-}" ] && [ "$agents_image" != "${AGENTS_IMAGE:-}" ]; then
  die "agents image mismatch"
fi

mapfile -t found < <(find "$dir" -maxdepth 1 -type f -name 'digest-*' -printf '%f\n' | sort)
[ "${#found[@]}" -eq 4 ] || die "expected exactly 4 digest files, found ${#found[@]}: ${found[*]:-none}"

expected=(
  digest-core-amd64
  digest-core-arm64
  digest-agents-amd64
  digest-agents-arm64
)
for name in "${expected[@]}"; do
  [ -f "$dir/$name" ] || die "missing digest file: $dir/$name"
done
for name in "${found[@]}"; do
  match=0
  for want in "${expected[@]}"; do
    if [ "$name" = "$want" ]; then match=1; fi
  done
  [ "$match" -eq 1 ] || die "unexpected digest file: $dir/$name"
done

read_digest() {
  local file="$1" value
  value="$(tr -d '[:space:]' < "$file")"
  [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid digest in $file: '$value'"
  printf '%s\n' "$value"
}

core_amd64="$(read_digest "$dir/digest-core-amd64")"
core_arm64="$(read_digest "$dir/digest-core-arm64")"
agents_amd64="$(read_digest "$dir/digest-agents-amd64")"
agents_arm64="$(read_digest "$dir/digest-agents-arm64")"

create_index() {
  local image="$1" amd64="$2" arm64="$3" json digest platforms
  docker buildx imagetools create -t "$image:$tag" \
    "$image@$amd64" "$image@$arm64" >/dev/null
  json="$(docker buildx imagetools inspect "$image:$tag" --format '{{json .Manifest}}')"
  digest="$(jq -r '.digest // empty' <<<"$json")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "index $image:$tag has no valid digest: '$digest'"
  platforms="$(jq -r '.manifests[]? | .platform | "\(.os)/\(.architecture)"' <<<"$json" | sort -u)"
  if [ "$platforms" != $'linux/amd64\nlinux/arm64' ]; then
    die "index $image:$tag platforms are '$platforms' (expected linux/amd64 + linux/arm64)"
  fi
  printf '%s\n' "$digest"
}

core_digest="$(create_index "$core_image" "$core_amd64" "$core_arm64")"
agents_digest="$(create_index "$agents_image" "$agents_amd64" "$agents_arm64")"

printf 'core_digest=%s\n' "$core_digest"
printf 'agents_digest=%s\n' "$agents_digest"
