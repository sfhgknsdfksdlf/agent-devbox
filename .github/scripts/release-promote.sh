#!/usr/bin/env bash
# Move exactly one channel alias (`latest` or `beta`) to a verified multi-arch
# index digest, with an all-or-nothing rollback.
#
# Contract:
#   * pre-promotion failure (bad args, failed --pre-check-cmd) -> zero alias writes
#   * first alias write fails -> restore the first alias (previous or absent)
#   * second alias/readback fails -> restore BOTH aliases
#       - previous digest present -> re-create the alias from it
#       - first-ever promotion    -> delete the alias and require a 404 readback
#   * rollback failure -> ALERT, exit 3; the caller must skip prune/state updates
#   * the previous digests + Release id are written to --state-file BEFORE any
#     write, for manual recovery
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
alert() {
  echo "::error::ALERT: $*" >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## ALERT: release alias rollback failed"
      echo
      echo "$*"
      echo
      echo "The promotion state file has the previous digests and Release id."
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

core_image=""
agents_image=""
alias=""
core_digest=""
agents_digest=""
release_tag=""
release_id=""
state_file=""
pre_check=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --core-image) core_image="$2"; shift 2 ;;
    --agents-image) agents_image="$2"; shift 2 ;;
    --alias) alias="$2"; shift 2 ;;
    --core-digest) core_digest="$2"; shift 2 ;;
    --agents-digest) agents_digest="$2"; shift 2 ;;
    --release-tag) release_tag="$2"; shift 2 ;;
    --release-id) release_id="$2"; shift 2 ;;
    --state-file) state_file="$2"; shift 2 ;;
    --pre-check-cmd) pre_check="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$core_image" ] || die "--core-image is required"
[ -n "$agents_image" ] || die "--agents-image is required"
case "$alias" in
  latest|beta) ;;
  *) die "--alias must be latest or beta (got '$alias')" ;;
esac
[[ "$core_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid --core-digest"
[[ "$agents_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid --agents-digest"
[ -n "$release_tag" ] || die "--release-tag is required"
[[ "$release_id" =~ ^[0-9]+$ ]] || die "invalid --release-id"
[ -n "$state_file" ] || die "--state-file is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

# Pre-promotion gate (for example: a final asset-manifest check). It runs before
# any registry/Release call so a failure can never leave a half-moved alias.
if [ -n "$pre_check" ]; then
  if ! bash -c "$pre_check"; then
    echo "pre-promotion check failed; zero alias writes" >&2
    exit 1
  fi
fi

# 0 = digest printed, 1 = tag absent (404), 2 = registry error.
inspect_digest() {
  local image="$1" tag="$2" out err tries=0
  out="$(mktemp)"
  err="$(mktemp)"
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    if docker buildx imagetools inspect "$image:$tag" --format '{{json .Manifest}}' >"$out" 2>"$err"; then
      jq -r '.digest // empty' <"$out"
      rm -f "$out" "$err"
      return 0
    fi
    if grep -Eqi 'not found|manifest unknown|404' "$err"; then
      rm -f "$out" "$err"
      return 1
    fi
    sleep 1
  done
  rm -f "$out" "$err"
  return 2
}

write_alias() {
  local image="$1" tag="$2" digest="$3"
  docker buildx imagetools create -t "$image:$tag" "$image@$digest" >/dev/null
}

# 0 = found (path printed), 1 = no version carries the tag, 2 = API error.
find_alias_version() {
  local image="$1" tag="$2" package owner base versions id saw_ok=0 saw_error=0
  package="${image##*/}"
  owner="${GITHUB_REPOSITORY_OWNER:-}"
  if [ -z "$owner" ]; then owner="${GITHUB_REPOSITORY%%/*}"; fi
  [ -n "$owner" ] || return 2
  for base in "orgs/$owner/packages/container/$package" "users/$owner/packages/container/$package"; do
    if versions="$(gh api "$base/versions?per_page=100" 2>/dev/null)"; then
      saw_ok=1
      id="$(jq -r --arg t "$tag" '.[]? | select((.metadata.container.tags // []) | index($t)) | .id' <<<"$versions" 2>/dev/null | head -n1 || true)"
      if [ -n "$id" ]; then
        printf '%s\n' "$base/$id"
        return 0
      fi
    else
      saw_error=1
    fi
  done
  if [ "$saw_ok" -eq 0 ] && [ "$saw_error" -eq 1 ]; then return 2; fi
  return 1
}

delete_alias() {
  local image="$1" tag="$2" path rc
  set +e
  path="$(find_alias_version "$image" "$tag")"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    gh api -X DELETE "$path" >/dev/null
    return $?
  fi
  if [ "$rc" -eq 1 ]; then
    return 0
  fi
  return 1
}

# Restore one alias to `previous` (a digest) or to absent.
restore_alias() {
  local image="$1" tag="$2" previous="$3" got
  if [ "$previous" = "absent" ]; then
    delete_alias "$image" "$tag" || return 1
    set +e
    inspect_digest "$image" "$tag" >/dev/null
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then return 1; fi
    if [ "$rc" -ne 1 ]; then return 1; fi
    echo "restored $image:$tag to absent (readback 404)" >&2
    return 0
  fi
  write_alias "$image" "$tag" "$previous" || return 1
  if ! got="$(inspect_digest "$image" "$tag")"; then return 1; fi
  [ "$got" = "$previous" ]
}

write_state() {
  local status="$1" tmp
  tmp="$state_file.tmp"
  jq -n \
    --arg status "$status" \
    --arg alias "$alias" \
    --arg release_tag "$release_tag" \
    --arg release_id "$release_id" \
    --arg new_core "$core_digest" \
    --arg new_agents "$agents_digest" \
    --arg prev_core "$prev_core" \
    --arg prev_agents "$prev_agents" \
    '{status:$status, alias:$alias, release_tag:$release_tag, release_id:$release_id,
      new:{core:$new_core, agents:$new_agents},
      previous:{core:$prev_core, agents:$prev_agents}}' > "$tmp"
  mv "$tmp" "$state_file"
}

rollback() {
  local failed=0
  if ! restore_alias "$core_image" "$alias" "$prev_core"; then failed=1; fi
  if ! restore_alias "$agents_image" "$alias" "$prev_agents"; then failed=1; fi
  return "$failed"
}

set +e
prev_core="$(inspect_digest "$core_image" "$alias")"
rc_core=$?
prev_agents="$(inspect_digest "$agents_image" "$alias")"
rc_agents=$?
set -e
if [ "$rc_core" -eq 1 ]; then prev_core="absent"; fi
if [ "$rc_agents" -eq 1 ]; then prev_agents="absent"; fi
if [ "$rc_core" -ne 0 ] && [ "$rc_core" -ne 1 ]; then die "cannot read previous $alias alias for $core_image"; fi
if [ "$rc_agents" -ne 0 ] && [ "$rc_agents" -ne 1 ]; then die "cannot read previous $alias alias for $agents_image"; fi
if [ "$rc_core" -eq 0 ] && ! [[ "$prev_core" =~ ^sha256:[0-9a-f]{64}$ ]]; then die "invalid previous $alias digest for $core_image"; fi
if [ "$rc_agents" -eq 0 ] && ! [[ "$prev_agents" =~ ^sha256:[0-9a-f]{64}$ ]]; then die "invalid previous $alias digest for $agents_image"; fi
write_state "promoting"

if ! write_alias "$core_image" "$alias" "$core_digest"; then
  echo "first alias write failed; rolling back the first alias" >&2
  if ! restore_alias "$core_image" "$alias" "$prev_core"; then
    write_state "rollback-failed"
    alert "first alias write failed and restoring $alias failed for $core_image"
    exit 3
  fi
  write_state "rolled-back"
  exit 1
fi

if ! write_alias "$agents_image" "$alias" "$agents_digest"; then
  echo "second alias write failed; rolling back both aliases" >&2
  if rollback; then
    write_state "rolled-back"
    echo "rollback complete" >&2
    exit 1
  fi
  write_state "rollback-failed"
  alert "second alias write failed and rollback did not converge"
  exit 3
fi

got_core=""
got_agents=""
if ! got_core="$(inspect_digest "$core_image" "$alias")"; then got_core="missing"; fi
if ! got_agents="$(inspect_digest "$agents_image" "$alias")"; then got_agents="missing"; fi
if [ "$got_core" != "$core_digest" ] || [ "$got_agents" != "$agents_digest" ]; then
  echo "alias readback mismatch (core=$got_core agents=$got_agents); rolling back" >&2
  if rollback; then
    write_state "rolled-back"
    echo "rollback complete" >&2
    exit 1
  fi
  write_state "rollback-failed"
  alert "alias readback mismatch and rollback did not converge"
  exit 3
fi

write_state "promoted"
printf 'promoted=%s\n' "$alias"
printf 'core_digest=%s\n' "$got_core"
printf 'agents_digest=%s\n' "$got_agents"
