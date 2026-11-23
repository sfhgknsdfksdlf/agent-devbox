#!/usr/bin/env bats
# P2-D2: windows/SHA256SUMS is generated from the git index only.
#
# Hermetic: every case builds a throwaway git repo under a temp dir and runs a
# COPY of the script there, so the real repository index is never touched. No
# network, no build. The manifest format stays `sha256  relative/name`.
#
# This file is not a plain bash script (`@test`), so `bash -n` does not apply.

setup() {
  SRC="$BATS_TEST_DIRNAME/../../.github/scripts/update-windows-sums.sh"
  TMP="$(mktemp -d)"
  WORK="$TMP/repo"
  LOCAL_SCRIPT="$WORK/.github/scripts/update-windows-sums.sh"
  MANIFEST="$WORK/windows/SHA256SUMS"

  mkdir -p "$WORK/.github/scripts" "$WORK/windows/sub"
  cp "$SRC" "$LOCAL_SCRIPT"
  chmod +x "$LOCAL_SCRIPT"

  # Ignore the host's user/system git config (autocrlf, signing, hooks).
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_TERMINAL_PROMPT=0

  git -C "$WORK" init -q
  git -C "$WORK" config user.email test@example.com
  git -C "$WORK" config user.name "Test"
  git -C "$WORK" config commit.gpgsign false

  printf 'alpha\n' > "$WORK/windows/alpha.ps1"
  printf 'beta\n' > "$WORK/windows/beta.cmd"
  printf 'readme\n' > "$WORK/windows/readme.md"
  printf 'nested\n' > "$WORK/windows/sub/nested.ps1"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q --no-gpg-sign -m baseline
}

teardown() {
  rm -rf "$TMP"
}

sha() {
  printf '%s\n' "$1" | sha256sum | cut -d' ' -f1
}

run_sums() {
  run bash "$LOCAL_SCRIPT"
}

@test "staged bytes win over a modified worktree" {
  printf 'staged\n' > "$WORK/windows/alpha.ps1"
  git -C "$WORK" add windows/alpha.ps1
  printf 'worktree\n' > "$WORK/windows/alpha.ps1"

  run_sums
  [ "$status" -eq 0 ]
  grep -qxF "$(sha staged)  alpha.ps1" "$MANIFEST"
  ! grep -qF "$(sha worktree)" "$MANIFEST"
}

@test "staged deletion drops the entry even if the worktree file remains" {
  git -C "$WORK" rm --cached -q windows/beta.cmd
  [ -f "$WORK/windows/beta.cmd" ]

  run_sums
  [ "$status" -eq 0 ]
  ! grep -q ' beta.cmd$' "$MANIFEST"
  grep -q ' alpha.ps1$' "$MANIFEST"
}

@test "untracked, non-script and nested files are absent" {
  printf 'new\n' > "$WORK/windows/untracked.ps1"

  run_sums
  [ "$status" -eq 0 ]
  ! grep -q 'untracked.ps1' "$MANIFEST"
  ! grep -q 'readme.md' "$MANIFEST"
  ! grep -q 'nested.ps1' "$MANIFEST"
}

@test "staged new file is included and order is lexicographic" {
  printf 'gamma\n' > "$WORK/windows/gamma.ps1"
  git -C "$WORK" add windows/gamma.ps1

  run_sums
  [ "$status" -eq 0 ]
  [ "$(awk '{print $2}' "$MANIFEST" | paste -sd, -)" = "alpha.ps1,beta.cmd,gamma.ps1" ]

  cp "$MANIFEST" "$TMP/first"
  run_sums
  [ "$status" -eq 0 ]
  diff -u "$TMP/first" "$MANIFEST"
}

@test "index-only blob without a worktree file is included" {
  blob="$(printf 'ghost\n' | git -C "$WORK" hash-object -w --stdin)"
  git -C "$WORK" update-index --add --cacheinfo "100644,$blob,windows/ghost.ps1"
  [ ! -e "$WORK/windows/ghost.ps1" ]

  run_sums
  [ "$status" -eq 0 ]
  grep -qxF "$(sha ghost)  ghost.ps1" "$MANIFEST"
}

@test "atomic replace leaves no temp file and exactly one trailing newline" {
  run_sums
  [ "$status" -eq 0 ]

  run bash -c 'find "$1" -maxdepth 1 -name ".SHA256SUMS.tmp.*" -print' _ "$WORK/windows"
  [ -z "$output" ]

  [ "$(wc -l < "$MANIFEST")" -eq 2 ]
  last_byte="$(tail -c 1 "$MANIFEST" | od -An -tx1 | tr -d ' \n')"
  [ "$last_byte" = "0a" ]
  last_two="$(tail -c 2 "$MANIFEST" | od -An -tx1 | tr -d ' \n')"
  [ "$last_two" != "0a0a" ]
}

@test "unreadable staged blob fails loudly and cleans up the temp file" {
  # A syntactically valid but non-existent object id: the index entry records
  # fine, but `git cat-file blob` cannot read it.
  missing="0123456789abcdef0123456789abcdef01234567"
  git -C "$WORK" update-index --add --cacheinfo "100644,$missing,windows/broken.ps1"

  run_sums
  [ "$status" -ne 0 ]
  [[ "$output" == *error* ]]
  [[ "$output" == *broken.ps1* ]]

  run bash -c 'find "$1" -maxdepth 1 -name ".SHA256SUMS.tmp.*" -print' _ "$WORK/windows"
  [ -z "$output" ]
}
