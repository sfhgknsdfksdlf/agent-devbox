#!/usr/bin/env bats
# version-inventory: record the MCP packages' real installed versions offline.
#
# Every external command is a temporary stub on PATH (npm/aider/go/gopls/dlv/
# wails3/uv/uvx/dpkg-query), and both MCP sources point at temp fixtures:
#   - AGENT_DEVBOX_UV_TOOLS_DIR  a fake uv tool tree with exactly one
#                                mcp_memory_service-*.dist-info/METADATA
#   - AGENT_DEVBOX_MCP_DAP_BIN   a fake binary whose module info comes from the
#                                `go version -m` stub
# No network, no docker, no writes outside TMP.

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  SCRIPT="$REPO_ROOT/scripts/version-inventory.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin" "$TMP/uv-tools" "$TMP/omo-cache/oh-my-openagent@1.2.3"
  export TMP

  printf '{"name":"oh-my-openagent","version":"1.2.3"}\n' \
    >"$TMP/omo-cache/oh-my-openagent@1.2.3/package.json"
  printf '#!/usr/bin/env bash\n:\n' >"$TMP/bin/mcp-dap-server"
  chmod 0755 "$TMP/bin/mcp-dap-server"

  write_mms_metadata 13.0.0
  install_stubs
}

teardown() {
  rm -rf "$TMP"
}

write_mms_metadata() {
  local version="$1"
  local dir="$TMP/uv-tools/mcp-memory-service/lib/python3.12/site-packages/mcp_memory_service-${version}.dist-info"
  mkdir -p "$dir"
  printf 'Metadata-Version: 2.1\nName: mcp-memory-service\nVersion: %s\n' "$version" \
    >"$dir/METADATA"
}

install_stubs() {
  cat >"$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "ls" ] || exit 2
printf '%s\n' '{"dependencies":{"opencode-ai":{"version":"1.19.5"},"open-websearch":{"version":"2.2.0"},"shadcn":{"version":"4.23.0"},"@playwright/mcp":{"version":"0.0.86"}}}'
EOF

  cat >"$TMP/bin/aider" <<'EOF'
#!/usr/bin/env bash
printf 'aider 0.86.2\n'
EOF

  cat >"$TMP/bin/gopls" <<'EOF'
#!/usr/bin/env bash
printf 'gopls v0.20.0\n'
EOF

  cat >"$TMP/bin/dlv" <<'EOF'
#!/usr/bin/env bash
printf 'Delve Debugger\nVersion: 1.26.0\n'
EOF

  cat >"$TMP/bin/wails3" <<'EOF'
#!/usr/bin/env bash
printf 'v3.0.0-beta.30\n'
EOF

  cat >"$TMP/bin/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv 0.13.9\n'
EOF

  cat >"$TMP/bin/uvx" <<'EOF'
#!/usr/bin/env bash
printf 'uvx 0.13.9\n'
EOF

  cat >"$TMP/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'base-files\t13.1\nlibc6\t2.41-12\n'
EOF

  # `go env GOVERSION` is preferred; `go version -m <binary>` supplies the
  # module line. STUB_DAP_MODE models the zero/multiple mod-line failures.
  cat >"$TMP/bin/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  env)
    printf 'go1.27.2\n'
    ;;
  version)
    if [ "${2:-}" = "-m" ]; then
      case "${STUB_DAP_MODE:-ok}" in
        ok)
          printf '%s: go1.27.2\n' "$3"
          printf '\tpath\tgithub.com/go-delve/mcp-dap-server\n'
          printf '\tmod\tgithub.com/go-delve/mcp-dap-server\t%s\th1:AAAA=\n' \
            "${STUB_DAP_VERSION:-v0.0.0-20261103230859-6011c2cd13e8}"
          ;;
        none)
          printf '%s: go1.27.2\n' "$3"
          printf '\tpath\tgithub.com/go-delve/mcp-dap-server\n'
          ;;
        dup)
          printf '%s: go1.27.2\n' "$3"
          printf '\tmod\tgithub.com/go-delve/mcp-dap-server\tv0.0.0-1\n'
          printf '\tmod\tgithub.com/go-delve/mcp-dap-server\tv0.0.0-2\n'
          ;;
        *)
          exit 2
          ;;
      esac
    else
      printf 'go version go1.27.2 linux/amd64\n'
    fi
    ;;
  *)
    exit 2
    ;;
esac
EOF

  chmod 0755 "$TMP/bin/"*
}

run_inventory() {
  run env \
    PATH="$TMP/bin:$PATH" \
    STUB_DAP_MODE="${STUB_DAP_MODE:-ok}" \
    STUB_DAP_VERSION="${STUB_DAP_VERSION:-v0.0.0-20261103230859-6011c2cd13e8}" \
    AGENT_DEVBOX_OMO_CACHE="$TMP/omo-cache" \
    AGENT_DEVBOX_UV_TOOLS_DIR="$TMP/uv-tools" \
    AGENT_DEVBOX_MCP_DAP_BIN="$TMP/bin/mcp-dap-server" \
    "$SCRIPT" --arch amd64 --variant agents
}

@test "records npm scoped key, uv dist-info version and the full Go module version" {
  run_inventory
  [ "$status" -eq 0 ]

  printf '%s' "$output" | jq -e '
    .schemaVersion == 1 and .arch == "amd64" and .variant == "agents"
  ' >/dev/null

  printf '%s' "$output" | jq -e '
    .tools["open-websearch"] == "2.2.0"
    and .tools["shadcn"] == "4.23.0"
    and .tools["@playwright/mcp"] == "0.0.86"
    and .tools["oh-my-openagent"] == "1.2.3"
    and .tools["go"] == "1.27.2"
    and .tools["aider-chat"] == "0.86.2"
  ' >/dev/null

  printf '%s' "$output" | jq -e '
    .tools["mcp-memory-service"] == "13.0.0"
  ' >/dev/null

  printf '%s' "$output" | jq -e '
    .tools["mcp-dap-server"] == "v0.0.0-20261103230859-6011c2cd13e8"
  ' >/dev/null
}

@test "scoped npm package is emitted exactly, never split or mangled" {
  run_inventory
  [ "$status" -eq 0 ]

  printf '%s' "$output" | jq -e '
    (.tools | has("@playwright/mcp"))
    and ((.tools | has("playwright/mcp")) | not)
    and ((.tools | has("@playwright")) | not)
    and ([.tools | keys[] | select(test("playwright"))] | length) == 1
  ' >/dev/null
}

@test "zero mcp_memory_service dist-info is fatal with a clear message" {
  rm -rf "$TMP/uv-tools/mcp-memory-service"
  run_inventory
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one mcp_memory_service dist-info"* ]]
}

@test "multiple mcp_memory_service dist-info entries are fatal" {
  write_mms_metadata 13.0.1
  run_inventory
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one mcp_memory_service dist-info"* ]]
  [[ "$output" == *"found 2"* ]]
}

@test "a dist-info without a Version line is fatal" {
  printf 'Metadata-Version: 2.1\nName: mcp-memory-service\n' \
    >"$TMP/uv-tools/mcp-memory-service/lib/python3.12/site-packages/mcp_memory_service-13.0.0.dist-info/METADATA"
  run_inventory
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot parse Version"* ]]
}

@test "zero mod lines for the Delve module are fatal" {
  STUB_DAP_MODE=none run_inventory
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one mod line for github.com/go-delve/mcp-dap-server"* ]]
  [[ "$output" == *"found 0"* ]]
}

@test "multiple mod lines for the Delve module are fatal" {
  STUB_DAP_MODE=dup run_inventory
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one mod line for github.com/go-delve/mcp-dap-server"* ]]
  [[ "$output" == *"found 2"* ]]
}

@test "a module version other than the fixed pseudo-version is recorded verbatim" {
  STUB_DAP_VERSION=v0.0.0-20270101000000-0123456789ab run_inventory
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .tools["mcp-dap-server"] == "v0.0.0-20270101000000-0123456789ab"
  ' >/dev/null
}

@test "missing mcp-dap-server binary is fatal" {
  rm -f "$TMP/bin/mcp-dap-server"
  run_inventory
  [ "$status" -ne 0 ]
  [[ "$output" == *"mcp-dap-server binary not found"* ]]
}
