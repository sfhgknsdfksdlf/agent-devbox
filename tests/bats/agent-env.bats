#!/usr/bin/env bats
# agent-env.sh shapes PATH/GOROOT without clobbering HOME.

setup() {
  export ENVSH="$BATS_TEST_DIRNAME/../../scripts/agent-env.sh"
}

@test "sets GOROOT and prepends go/bin to PATH" {
  run bash -c 'unset GOROOT GOPATH; . "$ENVSH"; echo "$GOROOT|$PATH"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/local/go"* ]]
  [[ "$output" == *"/usr/local/go/bin"* ]]
}

@test "does not modify HOME" {
  run bash -c 'export HOME=/tmp/keepme; . "$ENVSH"; echo "$HOME"'
  [ "$output" = "/tmp/keepme" ]
}
