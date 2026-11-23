#!/usr/bin/env bash
# Test harness for agent-devbox. bats is required: never pass silently without it.
set -euo pipefail

if ! command -v bats >/dev/null 2>&1; then
  echo "error: bats is required to run tests (install bats-core)." >&2
  exit 127
fi

cd -- "$(dirname -- "$0")/.."
exec bats tests/bats
