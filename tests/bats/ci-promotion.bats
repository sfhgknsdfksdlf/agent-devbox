#!/usr/bin/env bats
# P0-2 release protocol: executable fake-registry/fake-Release harness.
#
# The assertions are command/digest observations, not source text:
#   docker -> $FAKE_LOG (every imagetools call) + $STATE_DIR (tag -> digest)
#   gh     -> Release/package-version fake used by release-promote.sh rollback
#
# Scripts under test:
#   .github/scripts/release-tags.sh   plan/tag ordering
#   .github/scripts/merge-digests.sh  four digest files -> two index digests
#   .github/scripts/release-promote.sh alias transaction + rollback

setup() {
  TMP="$(mktemp -d)"
  export TMP
  export STATE_DIR="$TMP/registry"
  export FAKE_LOG="$TMP/commands.log"
  mkdir -p "$STATE_DIR" "$TMP/bin"
  : > "$FAKE_LOG"

  # Workflow-level image names must not leak into this fixture: the scripts
  # under test receive the explicit testowner image names below.
  unset CORE_IMAGE AGENTS_IMAGE

  export TAGS="$BATS_TEST_DIRNAME/../../.github/scripts/release-tags.sh"
  export MERGE="$BATS_TEST_DIRNAME/../../.github/scripts/merge-digests.sh"
  export PROMOTE="$BATS_TEST_DIRNAME/../../.github/scripts/release-promote.sh"
  export GITHUB_REPOSITORY_OWNER="testowner"
  export GITHUB_REPOSITORY="testowner/agent-devbox"
  export FAKE_TAG="beta"

  cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$FAKE_LOG"

key() {
  local img="${1%%:*}"
  local tag="${1##*:}"
  printf '%s_%s' "${img##*/}" "$tag"
}

if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] && [ "${3:-}" = "create" ]; then
  shift 3
  target=""
  sources=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -t) target="$2"; shift 2 ;;
      *) sources+=("$1"); shift ;;
    esac
  done
  [ -n "$target" ] || { echo "missing -t" >&2; exit 2; }
  [ "${#sources[@]}" -gt 0 ] || { echo "missing source" >&2; exit 2; }

  count_file="$STATE_DIR/.create-count"
  count=0
  [ -f "$count_file" ] && count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s' "$count" > "$count_file"
  if [ -n "${FAKE_FAIL_CREATE_CALLS:-}" ]; then
    case ",${FAKE_FAIL_CREATE_CALLS}," in
      *",${count},"*) echo "injected create failure #$count" >&2; exit 1 ;;
    esac
  fi
  if [ -n "${FAKE_FAIL_TARGET:-}" ] && [ "$target" = "$FAKE_FAIL_TARGET" ]; then
    echo "injected create failure $target" >&2
    exit 1
  fi

  k="$(key "$target")"
  if [ "${#sources[@]}" -eq 1 ]; then
    digest="${sources[0]#*@}"
    printf '%s\n' "$digest" > "$STATE_DIR/$k"
    rm -f "$STATE_DIR/$k.plats"
  else
    digest="sha256:$(printf '%s\n' "${sources[@]}" | sha256sum | cut -d' ' -f1)"
    printf '%s\n' "$digest" > "$STATE_DIR/$k"
    if [ "${FAKE_MISSING_PLATFORM:-}" = "arm64" ]; then
      printf 'linux/amd64\n' > "$STATE_DIR/$k.plats"
    else
      printf 'linux/amd64\nlinux/arm64\n' > "$STATE_DIR/$k.plats"
    fi
  fi
  printf '%s\n' "$digest"
  exit 0
fi

if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] && [ "${3:-}" = "inspect" ]; then
  ref="${4:-}"
  k="$(key "$ref")"
  if [ ! -f "$STATE_DIR/$k" ]; then
    echo "ERROR: not found: $ref" >&2
    exit 1
  fi
  digest="$(cat "$STATE_DIR/$k")"
  manifests=""
  if [ -f "$STATE_DIR/$k.plats" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      os="${p%%/*}"
      arch="${p##*/}"
      [ -z "$manifests" ] || manifests="$manifests,"
      manifests="$manifests{\"platform\":{\"os\":\"$os\",\"architecture\":\"$arch\"}}"
    done < "$STATE_DIR/$k.plats"
  fi
  printf '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"%s","manifests":[%s]}\n' "$digest" "$manifests"
  exit 0
fi

echo "unsupported fake docker invocation: $*" >&2
exit 2
DOCKER

  cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$FAKE_LOG"

[ "${1:-}" = "api" ] || exit 2
shift
args="$*"
pkg="$(printf '%s' "$args" | sed -n 's#.*container/\([^/]*\)/.*#\1#p')"
tag="${FAKE_TAG:-beta}"

if [[ "$args" == *"-X DELETE"* ]]; then
  rm -f "$STATE_DIR/${pkg}_${tag}"
  echo '{}'
  exit 0
fi
if [[ "$args" == *"/versions"* ]]; then
  if [ -f "$STATE_DIR/${pkg}_${tag}" ]; then
    printf '[{"id":42,"metadata":{"container":{"tags":["%s"]}}}]\n' "$tag"
  else
    printf '[]\n'
  fi
  exit 0
fi
exit 2
GH

  chmod +x "$TMP/bin/docker" "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

teardown() { rm -rf "$TMP"; }

sha_of() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }
seed_tag() {
  local img="$1" tag="$2" digest="$3"
  printf '%s\n' "$digest" > "$STATE_DIR/${img##*/}_${tag}"
}
tag_digest() {
  local img="$1" tag="$2"
  cat "$STATE_DIR/${img##*/}_${tag}"
}
core_img() { printf 'ghcr.io/testowner/agent-devbox-core'; }
agents_img() { printf 'ghcr.io/testowner/agent-devbox'; }

@test "plan: same-minute runs get distinct tags/release tags" {
  run "$TAGS" plan --event push --ref refs/heads/main --run-id 100 --attempt 1 --ts 20261123.1200
  [ "$status" -eq 0 ]
  [[ "$output" == *"tag=20261123.1200-100.1"* ]]
  [[ "$output" == *"release_tag=beta-20261123.1200-100.1"* ]]

  run "$TAGS" plan --event push --ref refs/heads/main --run-id 101 --attempt 1 --ts 20261123.1200
  [ "$status" -eq 0 ]
  [[ "$output" == *"tag=20261123.1200-101.1"* ]]
  [[ "$output" != *"tag=20261123.1200-100.1"* ]]
}

@test "plan: all three events use the approved tag/release_tag/alias table" {
  run "$TAGS" plan --event schedule --ref refs/heads/main --run-id 7 --attempt 3 --ts 20261123.1200
  [ "$status" -eq 0 ]
  [[ "$output" == *"tag=20261123.1200-7.3"* ]]
  [[ "$output" == *"release_tag=build-20261123.1200-7.3"* ]]
  [[ "$output" == *"promote=true"* ]]
  [[ "$output" == *"beta_alias=false"* ]]
  [[ "$output" == *"channel=stable"* ]]

  run "$TAGS" plan --event workflow_dispatch --ref refs/heads/main --run-id 8 --attempt 1 --ts 20261123.1200
  [ "$status" -eq 0 ]
  [[ "$output" == *"release_tag=build-20261123.1200-8.1"* ]]

  run "$TAGS" plan --event push --ref refs/heads/main --run-id 9 --attempt 1 --ts 20261123.1200
  [ "$status" -eq 0 ]
  [[ "$output" == *"tag=20261123.1200-9.1"* ]]
  [[ "$output" == *"release_tag=beta-20261123.1200-9.1"* ]]
  [[ "$output" == *"channel=beta"* ]]

  run "$TAGS" plan --event push --ref refs/heads/topic --run-id 10 --attempt 2 --ts 20261123.1200
  [ "$status" -eq 0 ]
  [[ "$output" == *"tag=beta-20261123.1200-10.2"* ]]
  [[ "$output" == *"release_tag=beta-20261123.1200-10.2"* ]]
}

@test "plan: empty/invalid run identity is rejected" {
  run "$TAGS" plan --event push --ref refs/heads/main --run-id '' --attempt 1 --ts 20261123.1200
  [ "$status" -ne 0 ]
  run "$TAGS" plan --event push --ref refs/heads/main --run-id 12 --attempt 0 --ts 20261123.1200
  [ "$status" -ne 0 ]
  run "$TAGS" plan --event push --ref refs/heads/main --run-id abc --attempt 1 --ts 20261123.1200
  [ "$status" -ne 0 ]
}

@test "ordering: older run/attempt and old date-only tags do not look newest" {
  # run 100 started later than 99 at the same minute: 100 wins.
  run "$TAGS" is-newer --candidate beta-20261123.1200-100.1 --latest beta-20261123.1200-99.9
  [ "$status" -eq 0 ]
  run "$TAGS" is-newer --candidate beta-20261123.1200-99.9 --latest beta-20261123.1200-100.1
  [ "$status" -eq 1 ]
  # same run, higher attempt wins.
  run "$TAGS" is-newer --candidate beta-20261123.1200-100.2 --latest beta-20261123.1200-100.1
  [ "$status" -eq 0 ]
  run "$TAGS" is-newer --candidate beta-20261123.1200-100.1 --latest beta-20261123.1200-100.2
  [ "$status" -eq 1 ]
  # equal is not newer unless explicitly allowed.
  run "$TAGS" is-newer --candidate beta-20261123.1200-100.1 --latest beta-20261123.1200-100.1
  [ "$status" -eq 1 ]
  run "$TAGS" is-newer --candidate beta-20261123.1200-100.1 --latest beta-20261123.1200-100.1 --allow-equal
  [ "$status" -eq 0 ]
  # date-only legacy tag is older than a suffixed tag in the same minute.
  run "$TAGS" is-newer --candidate beta-20261123.1200-1.1 --latest beta-20261123.1200
  [ "$status" -eq 0 ]
  run "$TAGS" is-newer --candidate beta-20261123.1200 --latest beta-20261123.1200-1.1
  [ "$status" -eq 1 ]
  # a later date is newer even with a smaller run id.
  run "$TAGS" is-newer --candidate beta-20261123.1201-1.1 --latest beta-20261123.1200-999.9
  [ "$status" -eq 0 ]
}

@test "ordering: newest picks the maximum beta tag from a mixed list" {
  run bash -c "printf '%s\n' beta-20261123.1200 beta-20261123.1200-5.1 beta-20261123.1200-12.1 beta-20261122.2359-999.1 | '$TAGS' newest"
  [ "$status" -eq 0 ]
  [ "$output" = "beta-20261123.1200-12.1" ]
}

@test "merge: exactly four digest files become two index digests" {
  mkdir -p "$TMP/digests"
  a="$(sha_of core-amd64)"; b="$(sha_of core-arm64)"
  c="$(sha_of agents-amd64)"; d="$(sha_of agents-arm64)"
  printf '%s\n' "$a" > "$TMP/digests/digest-core-amd64"
  printf '%s\n' "$b" > "$TMP/digests/digest-core-arm64"
  printf '%s\n' "$c" > "$TMP/digests/digest-agents-amd64"
  printf '%s\n' "$d" > "$TMP/digests/digest-agents-arm64"

  run "$MERGE" --dir "$TMP/digests" --tag 20261123.1200-100.1 \
    --core-image "$(core_img)" --agents-image "$(agents_img)"
  [ "$status" -eq 0 ]
  [[ "$output" == core_digest=sha256:* ]]
  [[ "$output" == *"agents_digest=sha256:"* ]]
  grep -q "create -t $(core_img):20261123.1200-100.1 $(core_img)@$a $(core_img)@$b" "$FAKE_LOG"
  grep -q "create -t $(agents_img):20261123.1200-100.1 $(agents_img)@$c $(agents_img)@$d" "$FAKE_LOG"
}

@test "merge: missing or malformed digest is rejected before any create" {
  mkdir -p "$TMP/digests"
  a="$(sha_of core-amd64)"
  printf '%s\n' "$a" > "$TMP/digests/digest-core-amd64"
  printf '%s\n' "$a" > "$TMP/digests/digest-core-arm64"
  printf '%s\n' "$a" > "$TMP/digests/digest-agents-amd64"

  run "$MERGE" --dir "$TMP/digests" --tag 20261123.1200-100.1 \
    --core-image "$(core_img)" --agents-image "$(agents_img)"
  [ "$status" -ne 0 ]
  ! grep -q 'imagetools create' "$FAKE_LOG"

  printf '%s\n' "$a" > "$TMP/digests/digest-agents-arm64"
  printf 'sha256:not-a-digest\n' > "$TMP/digests/digest-agents-arm64"
  run "$MERGE" --dir "$TMP/digests" --tag 20261123.1200-100.1 \
    --core-image "$(core_img)" --agents-image "$(agents_img)"
  [ "$status" -ne 0 ]
  ! grep -q 'imagetools create' "$FAKE_LOG"
}

@test "merge: an index missing arm64 is rejected" {
  mkdir -p "$TMP/digests"
  for f in core-amd64 core-arm64 agents-amd64 agents-arm64; do
    printf '%s\n' "$(sha_of "$f")" > "$TMP/digests/digest-$f"
  done
  export FAKE_MISSING_PLATFORM=arm64
  run "$MERGE" --dir "$TMP/digests" --tag 20261123.1200-100.1 \
    --core-image "$(core_img)" --agents-image "$(agents_img)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"platform"* || "$output" == *"arm64"* ]]
  [[ "$output" != *"core_digest="* ]]
}

@test "promotion: pre-promotion failure performs zero alias writes" {
  old_core="$(sha_of old-core)"; old_agents="$(sha_of old-agents)"
  seed_tag "$(core_img)" beta "$old_core"
  seed_tag "$(agents_img)" beta "$old_agents"

  run "$PROMOTE" --core-image "$(core_img)" --agents-image "$(agents_img)" \
    --alias beta --core-digest "$(sha_of new-core)" --agents-digest "$(sha_of new-agents)" \
    --release-tag beta-20261123.1200-100.1 --release-id 99 \
    --state-file "$TMP/promotion-state.json" --pre-check-cmd false
  [ "$status" -ne 0 ]
  ! grep -q 'imagetools create' "$FAKE_LOG"
  [ "$(tag_digest "$(core_img)" beta)" = "$old_core" ]
  [ "$(tag_digest "$(agents_img)" beta)" = "$old_agents" ]
}

@test "promotion: second alias failure restores both previous digests" {
  old_core="$(sha_of old-core)"; old_agents="$(sha_of old-agents)"
  new_core="$(sha_of new-core)"; new_agents="$(sha_of new-agents)"
  seed_tag "$(core_img)" beta "$old_core"
  seed_tag "$(agents_img)" beta "$old_agents"
  export FAKE_FAIL_CREATE_CALLS=2   # first write ok, second alias fails

  run "$PROMOTE" --core-image "$(core_img)" --agents-image "$(agents_img)" \
    --alias beta --core-digest "$new_core" --agents-digest "$new_agents" \
    --release-tag beta-20261123.1200-100.1 --release-id 99 \
    --state-file "$TMP/promotion-state.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rolling back"* ]]
  [ "$(tag_digest "$(core_img)" beta)" = "$old_core" ]
  [ "$(tag_digest "$(agents_img)" beta)" = "$old_agents" ]
  grep -q "create -t $(core_img):beta $(core_img)@$new_core" "$FAKE_LOG"
  grep -q "create -t $(core_img):beta $(core_img)@$old_core" "$FAKE_LOG"
  grep -q "create -t $(agents_img):beta $(agents_img)@$old_agents" "$FAKE_LOG"
}

@test "promotion: first-ever second-alias failure deletes the first alias (readback 404)" {
  new_core="$(sha_of new-core)"; new_agents="$(sha_of new-agents)"
  export FAKE_FAIL_CREATE_CALLS=2

  run "$PROMOTE" --core-image "$(core_img)" --agents-image "$(agents_img)" \
    --alias beta --core-digest "$new_core" --agents-digest "$new_agents" \
    --release-tag beta-20261123.1200-100.1 --release-id 99 \
    --state-file "$TMP/promotion-state.json"
  [ "$status" -ne 0 ]
  grep -q 'gh api -X DELETE' "$FAKE_LOG"
  [ ! -f "$STATE_DIR/agent-devbox-core_beta" ]
  [[ "$output" == *"absent"* ]]
}

@test "promotion: rollback failure alerts and the guarded prune/state never runs" {
  old_core="$(sha_of old-core)"; old_agents="$(sha_of old-agents)"
  seed_tag "$(core_img)" beta "$old_core"
  seed_tag "$(agents_img)" beta "$old_agents"
  export FAKE_FAIL_CREATE_CALLS=2,3   # second alias fails, core restore also fails

  cat > "$TMP/guarded.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
rc=0
"$PROMOTE" "\$@" || rc=\$?
if [ "\$rc" -eq 0 ]; then
  : > "$TMP/ran-prune"
  : > "$TMP/ran-state"
fi
exit "\$rc"
EOF
  chmod +x "$TMP/guarded.sh"

  run "$TMP/guarded.sh" --core-image "$(core_img)" --agents-image "$(agents_img)" \
    --alias beta --core-digest "$(sha_of new-core)" --agents-digest "$(sha_of new-agents)" \
    --release-tag beta-20261123.1200-100.1 --release-id 99 \
    --state-file "$TMP/promotion-state.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ALERT"* ]]
  [ ! -e "$TMP/ran-prune" ]
  [ ! -e "$TMP/ran-state" ]
}

@test "promotion: success writes both aliases, reads them back and records state" {
  old_core="$(sha_of old-core)"; old_agents="$(sha_of old-agents)"
  new_core="$(sha_of new-core)"; new_agents="$(sha_of new-agents)"
  seed_tag "$(core_img)" beta "$old_core"
  seed_tag "$(agents_img)" beta "$old_agents"

  run "$PROMOTE" --core-image "$(core_img)" --agents-image "$(agents_img)" \
    --alias beta --core-digest "$new_core" --agents-digest "$new_agents" \
    --release-tag beta-20261123.1200-100.1 --release-id 99 \
    --state-file "$TMP/promotion-state.json"
  [ "$status" -eq 0 ]
  [ "$(tag_digest "$(core_img)" beta)" = "$new_core" ]
  [ "$(tag_digest "$(agents_img)" beta)" = "$new_agents" ]
  [ "$(jq -r .status "$TMP/promotion-state.json")" = "promoted" ]
  [ "$(jq -r .previous.core "$TMP/promotion-state.json")" = "$old_core" ]
  [ "$(jq -r .release_id "$TMP/promotion-state.json")" = "99" ]
}

@test "promotion: malformed digest is rejected before touching the registry" {
  run "$PROMOTE" --core-image "$(core_img)" --agents-image "$(agents_img)" \
    --alias beta --core-digest sha256:short --agents-digest "$(sha_of new-agents)" \
    --release-tag beta-20261123.1200-100.1 --release-id 99 \
    --state-file "$TMP/promotion-state.json"
  [ "$status" -ne 0 ]
  [ ! -s "$FAKE_LOG" ]
}
