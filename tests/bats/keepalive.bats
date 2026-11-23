#!/usr/bin/env bats
# P2-D4: hermetic keepalive tests against a temporary bare git remote.
#
# The script must be serialized by its git-dir flock: two concurrent runs on an
# old main produce exactly ONE empty commit. A non-main branch never pushes.

setup() {
  TMP="$(mktemp -d)"
  export TMP
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/.github/scripts/keepalive.sh"
  BARE="$TMP/origin.git"
  WORK="$TMP/work"
  NOW="$(date -u +%s)"
  OLD="$((NOW - 60 * 86400))"

  git init --bare -q -b main "$BARE"
  git clone -q "$BARE" "$WORK"
  git -C "$WORK" config user.name "Test User"
  git -C "$WORK" config user.email "test@example.com"
  git -C "$WORK" config commit.gpgsign false

  GIT_AUTHOR_DATE="@$OLD +0000" GIT_COMMITTER_DATE="@$OLD +0000" \
    git -C "$WORK" commit -q --allow-empty -m "old main tip"
  git -C "$WORK" push -q origin main
}

teardown() {
  rm -rf "$TMP"
}

count_main() {
  git -C "$BARE" rev-list --count main
}

@test "keepalive: an old main gets exactly one empty commit" {
  before="$(count_main)"
  run bash -c 'cd "$1" && "$2" --branch main --now "$3"' _ "$WORK" "$SCRIPT" "$NOW"
  [ "$status" -eq 0 ]
  [ "$(count_main)" -eq "$((before + 1))" ]
  [ "$(git -C "$BARE" log -1 --format=%s main)" = "chore: keepalive (avoid 60-day schedule auto-disable)" ]
}

@test "keepalive: two concurrent runs produce exactly one commit" {
  before="$(count_main)"
  ( cd "$WORK" && bash "$SCRIPT" --branch main --now "$NOW" >"$TMP/a.log" 2>&1 ) &
  a=$!
  ( cd "$WORK" && bash "$SCRIPT" --branch main --now "$NOW" >"$TMP/b.log" 2>&1 ) &
  b=$!
  wait "$a"; ra=$?
  wait "$b"; rb=$?
  [ "$ra" -eq 0 ]
  [ "$rb" -eq 0 ]
  [ "$(count_main)" -eq "$((before + 1))" ]
}

@test "keepalive: a recent main is left alone" {
  git -C "$WORK" commit -q --allow-empty -m "recent main tip"
  git -C "$WORK" push -q origin main
  before="$(count_main)"
  run bash -c 'cd "$1" && "$2" --branch main --now "$3"' _ "$WORK" "$SCRIPT" "$NOW"
  [ "$status" -eq 0 ]
  [ "$(count_main)" -eq "$before" ]
}

@test "keepalive: a non-main branch never pushes" {
  before="$(count_main)"
  run bash -c 'cd "$1" && "$2" --branch feature --now "$3"' _ "$WORK" "$SCRIPT" "$NOW"
  [ "$status" -eq 0 ]
  [ "$(count_main)" -eq "$before" ]
  [[ "$output" == *"not main"* ]]
}
