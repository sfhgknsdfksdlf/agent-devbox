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

@test "derives GOPATH/GOCACHE from HOME and prefixes PATH in order" {
  run bash -c 'export HOME=/home/alice; unset GOPATH GOCACHE; . "$ENVSH"; printf "%s\n%s\n%s\n%s\n" "$GOPATH" "$GOCACHE" "$HOME" "$PATH"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "/home/alice/go" ]
  [ "${lines[1]}" = "/home/alice/.cache/go-build" ]
  [ "${lines[2]}" = "/home/alice" ]
  [[ "${lines[3]}" == /usr/local/go/bin:/home/alice/go/bin:/usr/local/bin:* ]]
}

@test "unset HOME synthesizes no GOPATH/GOCACHE and does not set HOME (set -u)" {
  run env -u HOME bash -c 'set -u; unset GOPATH GOCACHE; . "$ENVSH"; printf "GOPATH=%s\n" "${GOPATH-<unset>}"; printf "GOCACHE=%s\n" "${GOCACHE-<unset>}"; printf "HOME=%s\n" "${HOME-<unset>}"; printf "PATH=%s\n" "$PATH"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "GOPATH=<unset>" ]
  [ "${lines[1]}" = "GOCACHE=<unset>" ]
  [ "${lines[2]}" = "HOME=<unset>" ]
  [[ "${lines[3]}" != *":/go/bin:"* ]]
  [[ "${lines[3]}" != *".cache"* ]]
}

@test "empty HOME synthesizes no GOPATH/GOCACHE" {
  run env HOME= bash -c 'set -u; unset GOPATH GOCACHE; . "$ENVSH"; printf "GOPATH=%s\n" "${GOPATH-<unset>}"; printf "GOCACHE=%s\n" "${GOCACHE-<unset>}"; printf "HOME=%s\n" "${HOME-<unset>}"; printf "PATH=%s\n" "$PATH"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "GOPATH=<unset>" ]
  [ "${lines[1]}" = "GOCACHE=<unset>" ]
  [ "${lines[2]}" = "HOME=" ]
  [[ "${lines[3]}" != *":/go/bin:"* ]]
  [[ "${lines[3]}" != *".cache"* ]]
}

@test "preserves non-empty GOPATH/GOCACHE and uses GOPATH/bin" {
  run bash -c 'export HOME=/home/dana GOPATH=/opt/custom-go GOCACHE=/var/cache/custom; . "$ENVSH"; printf "%s\n%s\n%s\n" "$GOPATH" "$GOCACHE" "$PATH"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "/opt/custom-go" ]
  [ "${lines[1]}" = "/var/cache/custom" ]
  [[ "${lines[2]}" == /usr/local/go/bin:/opt/custom-go/bin:/usr/local/bin:* ]]
}

@test "deduplicates PATH components, keeps the first occurrence, preserves spaces" {
  run bash -c 'export HOME=/home/bob; unset GOPATH GOCACHE; export PATH="/usr/local/go/bin:/usr/local/bin:/usr/bin:/usr/local/go/bin:/bin:/opt/my tools/bin"; . "$ENVSH"; printf "%s" "$PATH"'
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/local/go/bin:/home/bob/go/bin:/usr/local/bin:/usr/bin:/bin:/opt/my tools/bin" ]
}

@test "sourcing twice leaves PATH byte-identical without duplicate go/bin" {
  run bash -c 'export HOME=/home/carol; unset GOPATH GOCACHE; export PATH="/usr/bin:/bin"; . "$ENVSH"; printf "%s\n" "$PATH"; . "$ENVSH"; printf "%s\n" "$PATH"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "${lines[1]}" ]
  [ "$(printf '%s' "${lines[1]}" | tr ':' '\n' | grep -c '^/usr/local/go/bin$')" -eq 1 ]
  [ "$(printf '%s' "${lines[1]}" | tr ':' '\n' | grep -c '^/home/carol/go/bin$')" -eq 1 ]
}

@test "profile hook sources agent-env only for Bash login shells" {
  hook="$BATS_TEST_TMPDIR/agent-devbox.sh"
  marker="$BATS_TEST_TMPDIR/agent-env-marker.sh"
  printf 'AGENT_ENV_MARKER=loaded\nexport AGENT_ENV_MARKER\n' > "$marker"
  sed "s#/usr/local/bin/agent-env.sh#$marker#" \
    "$BATS_TEST_DIRNAME/../../config/profile.d/agent-devbox.sh" > "$hook"

  run env -u BASH_VERSION dash -c '. "$1"; printf "marker=%s\n" "${AGENT_ENV_MARKER:-}"' sh "$hook"
  [ "$status" -eq 0 ]
  [ "$output" = "marker=" ]

  run env -u BASH_VERSION bash -c '. "$1"; printf "marker=%s\n" "${AGENT_ENV_MARKER:-}"' sh "$hook"
  [ "$status" -eq 0 ]
  [ "$output" = "marker=loaded" ]
}
