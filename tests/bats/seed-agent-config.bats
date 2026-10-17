#!/usr/bin/env bats
# Idempotent, no-overwrite seeding of the omo/OpenCode config.

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export AGENT_SEED_DIR="$TMP/seed"
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/seed-agent-config.sh"
  mkdir -p "$HOME" "$AGENT_SEED_DIR/.config/opencode" "$AGENT_SEED_DIR/.omo"
  echo '{"plugin":["oh-my-openagent@latest"]}' > "$AGENT_SEED_DIR/.config/opencode/opencode.json"
  echo 'seed' > "$AGENT_SEED_DIR/.omo/omo.jsonc"
}

teardown() { rm -rf "$TMP"; }

@test "seeds missing config into HOME" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.config/opencode/opencode.json" ]
  [ -f "$HOME/.omo/omo.jsonc" ]
}

@test "does not overwrite existing user config" {
  mkdir -p "$HOME/.config/opencode"
  echo '{"user":true}' > "$HOME/.config/opencode/opencode.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '"user":true' "$HOME/.config/opencode/opencode.json"
}

@test "no-op when the seed dir is absent" {
  rm -rf "$AGENT_SEED_DIR"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}
