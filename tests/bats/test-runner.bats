#!/usr/bin/env bats
# tests/run.sh must fail loudly without bats and exec the suite when bats exists.
bats_require_minimum_version 1.5.0

setup() {
  TMP=""
  RUNNER="$BATS_TEST_DIRNAME/../run.sh"
}

teardown() {
  if [ -n "$TMP" ]; then
    rm -rf "$TMP"
  fi
}

@test "missing bats fails on stderr instead of silently skipping" {
  # PATH=/nonexistent also proves the check runs before dirname/bats.
  run ! /bin/bash -c 'PATH=/nonexistent /bin/bash "$1" 2>&1 >/dev/null' _ "$RUNNER"
  [ "$status" -ne 0 ]
  [[ "$output" == *bats* ]]
  [[ "$output" == *required* || "$output" == *install* ]]
}

@test "normal path execs bats with tests/bats" {
  TMP="$(mktemp -d)"
  local log="$TMP/bats.log"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/bats" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$FAKE_BATS_LOG"
EOF
  chmod +x "$TMP/bin/bats"

  run env PATH="$TMP/bin:$PATH" FAKE_BATS_LOG="$log" /bin/bash "$RUNNER"
  local rc="$status"
  local logged=""
  if [ -f "$log" ]; then
    logged="$(cat "$log")"
  fi
  [ "$rc" -eq 0 ]
  [ "$logged" = "tests/bats" ]
}
