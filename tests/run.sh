#!/usr/bin/env bash
# Test harness for agent-devbox. Runs the bats suite when bats is available.
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v bats >/dev/null 2>&1; then
  exec bats tests/bats
else
  echo "bats not installed; skipping unit tests (CI installs it)."
fi
