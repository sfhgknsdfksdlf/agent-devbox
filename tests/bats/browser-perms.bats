#!/usr/bin/env bats
# P2-A3: the shared Playwright browser tree must be root-owned and writable by
# nobody but root (defence in depth for the unprivileged `paseo` daemon), while
# staying readable/executable so the bundled Chromium still launches.
#
# Offline: no docker, no network. The static tests pin the Dockerfile lines;
# the fixture test replays the exact chmod expression on a temporary tree
# shaped like /ms-playwright. Assertions are mode-bit based (the suite may run
# as root); group/other write bits are what must never come back.

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  DOCKERFILE="$REPO_ROOT/Dockerfile"
  TMP="$(mktemp -d)"
  FIXTURE="$TMP/ms-playwright"
}

teardown() {
  rm -rf "$TMP"
}

mode_of() { # $1 = path
  stat -c '%a' -- "$1"
}

@test "Dockerfile hardens /ms-playwright instead of recursive 777" {
  if grep -qF 'chmod -R 777 /ms-playwright' "$DOCKERFILE"; then
    echo "recursive 777 on the shared browser tree must not return" >&2
    return 1
  fi
  grep -qF 'chown -R root:root /ms-playwright' "$DOCKERFILE"
  grep -qF 'chmod -R a+rX,go-w /ms-playwright' "$DOCKERFILE"
}

@test "Dockerfile keeps chromium discovery and the stable symlinks" {
  grep -qF 'find /ms-playwright -type f -name chrome' "$DOCKERFILE"
  grep -qF 'ln -sf "$chrome" /usr/local/bin/chromium' "$DOCKERFILE"
  grep -qF 'headless_shell' "$DOCKERFILE"
}

@test "fixture: hardened tree stays readable/executable and never writable" {
  local chrome_dir="$FIXTURE/chromium-1234/chrome-linux"
  local chrome="$chrome_dir/chrome"
  local data="$chrome_dir/data.txt"

  mkdir -p "$chrome_dir"
  printf '#!/bin/sh\nexit 0\n' > "$chrome"
  printf 'data\n' > "$data"
  # Worst case before hardening: a world-writable tree (the old 777).
  chmod 777 "$chrome_dir"
  chmod 755 "$chrome"
  chmod 644 "$data"

  # Replay the exact Dockerfile expression, retargeted at the fixture, so a
  # revert to `chmod -R 777` fails here as well as in the static test.
  local expr
  expr="$(grep -oE 'chmod -R [^ ;]+ /ms-playwright' "$DOCKERFILE" | head -n1)"
  [ -n "$expr" ] || { echo "no chmod /ms-playwright expression in Dockerfile" >&2; return 1; }
  expr="${expr/\/ms-playwright/$FIXTURE}"
  # shellcheck disable=SC2086 # deliberate word splitting: chmod -R <mode> <dir>
  $expr

  # Directories: 0755 (group/other r-x, no write).
  [ "$(mode_of "$FIXTURE/chromium-1234")" = 755 ]
  [ "$(mode_of "$chrome_dir")" = 755 ]
  # The fake browser must stay executable (a+X only adds X where it existed).
  [ "$(mode_of "$chrome")" = 755 ]
  [ -x "$chrome" ]
  # Plain data keeps 0644 (a+X does not invent execute bits).
  [ "$(mode_of "$data")" = 644 ]
  [ -r "$data" ]

  # No group/other write bit anywhere: this is the "paseo cannot modify the
  # shared browsers" invariant, checked without relying on a real paseo user.
  run find "$FIXTURE" -perm /022 -print
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # "paseo" (uid != 0) reads via other bits: r-x on dirs, r on data.
  [ "$(mode_of "$chrome_dir" | cut -c3)" = 5 ]
  [ "$(mode_of "$chrome" | cut -c3)" = 5 ]
  [ "$(mode_of "$data" | cut -c3)" = 4 ]
}
