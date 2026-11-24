#!/usr/bin/env bats
# T1a: the managed OpenCode V1 global MCP config and its uid-dropping launchers.
#
# Offline: no docker build, no network, no opencode binary required. The source
# of truth is config/opencode/global-mcp.json (rendered to /etc/opencode/
# opencode.json at build time); the launcher tests replay the real scripts with
# a fake `id` (forces the root branch) and a fake `gosu` that records its argv.

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  CONFIG="$REPO_ROOT/config/opencode/global-mcp.json"
  DOCKERFILE="$REPO_ROOT/Dockerfile"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  export GOSU_LOG="$TMP/gosu.log"
  printf '#!/bin/sh\necho 0\n' > "$TMP/bin/id"
  cat > "$TMP/bin/gosu" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$GOSU_LOG"
EOF
  chmod +x "$TMP/bin/id" "$TMP/bin/gosu"
}

teardown() {
  rm -rf "$TMP"
}

@test "global-mcp.json is strict JSON with only \$schema and mcp" {
  run jq -e 'type == "object" and keys == ["$schema", "mcp"]' "$CONFIG"
  [ "$status" -eq 0 ]
}

@test "managed mcp holds exactly the eight non-omo adapters" {
  run jq -e '.mcp | length == 8' "$CONFIG"
  [ "$status" -eq 0 ]
  run jq -r '.mcp | keys | join(",")' "$CONFIG"
  [ "$output" = "deepwiki,delve,memory,playwright,shadcn,tavily,wails3,websearch" ]
}

@test "managed mcp never redeclares omo-injected servers or a plugin array" {
  run jq -e '(.mcp | has("context7") or has("grep_app") or has("lsp")) | not' "$CONFIG"
  [ "$status" -eq 0 ]
  run jq -e 'has("plugin") | not' "$CONFIG"
  [ "$status" -eq 0 ]
  # A managed `plugin` array would replace omo's runtime-injected plugin.
  run grep -qi 'oh-my-openagent' "$CONFIG"
  [ "$status" -ne 0 ]
}

@test "memory is a remote, non-oauth server driven by env interpolation" {
  run jq -e '.mcp.memory == {
    "type": "remote",
    "url": "{env:OPENCODE_MEMORY_ENDPOINT}/mcp",
    "headers": {"X-API-Key": "{env:OPENCODE_MEMORY_API_KEY}"},
    "oauth": false,
    "enabled": true
  }' "$CONFIG"
  [ "$status" -eq 0 ]
}

@test "tavily keeps the keyless access-mode header" {
  run jq -e '.mcp.tavily == {
    "type": "remote",
    "url": "https://mcp.tavily.com/mcp/",
    "headers": {"X-Tavily-Access-Mode": "keyless"},
    "enabled": true
  }' "$CONFIG"
  [ "$status" -eq 0 ]
}

@test "websearch runs the local open-websearch with the bing-only environment" {
  run jq -e '.mcp.websearch == {
    "type": "local",
    "command": ["/usr/local/bin/open-websearch"],
    "environment": {
      "MODE": "stdio",
      "DEFAULT_SEARCH_ENGINE": "bing",
      "ALLOWED_SEARCH_ENGINES": "bing,baidu",
      "SEARCH_MODE": "request",
      "PLAYWRIGHT_NAVIGATION_TIMEOUT_MS": "20000"
    },
    "enabled": true
  }' "$CONFIG"
  [ "$status" -eq 0 ]
}

@test "local adapters use absolute build-time binaries, never npx/uvx" {
  run jq -e '.mcp.shadcn.command == ["/usr/local/bin/shadcn", "mcp"]
    and .mcp.wails3.command == ["/usr/local/bin/wails3", "mcp"]
    and .mcp.playwright.command == ["/usr/local/bin/playwright-mcp-launcher.sh"]
    and .mcp.delve.command == ["/usr/local/bin/mcp-dap-launcher.sh"]' "$CONFIG"
  [ "$status" -eq 0 ]
  run grep -RIlE '(^|[^a-zA-Z0-9_-])(npx|uvx)([^a-zA-Z0-9_-]|$)' "$REPO_ROOT/config/opencode"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "playwright launcher drops root to paseo and scopes --no-sandbox to itself" {
  run env PATH="$TMP/bin:$PATH" \
    AGENT_DEVBOX_ID_BIN="$TMP/bin/id" GOSU_LOG="$GOSU_LOG" \
    "$REPO_ROOT/scripts/playwright-mcp-launcher.sh" alpha beta
  [ "$status" -eq 0 ]
  [ "$(cat "$GOSU_LOG")" = "paseo env HOME=/home/paseo /usr/local/bin/playwright-mcp --headless --isolated --executable-path /usr/local/bin/chromium --no-sandbox alpha beta" ]
  # --no-sandbox belongs to this wrapper only, never to a global ENV.
  run grep -nE '^ENV .*(NO_SANDBOX|--no-sandbox)' "$DOCKERFILE"
  [ "$status" -ne 0 ]
  run grep -n -- '--no-sandbox' "$DOCKERFILE"
  [ "$status" -ne 0 ]
}

@test "delve launcher drops root to paseo and forwards argv" {
  run env PATH="$TMP/bin:$PATH" \
    AGENT_DEVBOX_ID_BIN="$TMP/bin/id" GOSU_LOG="$GOSU_LOG" \
    "$REPO_ROOT/scripts/mcp-dap-launcher.sh" alpha beta
  [ "$status" -eq 0 ]
  [ "$(cat "$GOSU_LOG")" = "paseo env HOME=/home/paseo /usr/local/bin/mcp-dap-server alpha beta" ]
}

@test "Dockerfile installs the adapters and renders the managed config" {
  grep -qF 'ARG CACHEBUST=0' "$DOCKERFILE"
  grep -qF 'ARG MMS_VERSION=13.0.0' "$DOCKERFILE"
  grep -qF 'ARG MCP_DAP_VERSION=v0.0.0-20261103230859-6011c2cd13e8' "$DOCKERFILE"
  grep -qF 'npm install -g open-websearch@latest shadcn@latest @playwright/mcp@latest' "$DOCKERFILE"
  grep -qF 'uv tool install "mcp-memory-service[sqlite]==${MMS_VERSION}"' "$DOCKERFILE"
  grep -qF 'go install "github.com/go-delve/mcp-dap-server@${MCP_DAP_VERSION}"' "$DOCKERFILE"
  grep -qF 'COPY config/opencode/global-mcp.json /etc/opencode/opencode.json' "$DOCKERFILE"
  grep -qF 'COPY config/agent-memory/ /opt/agent-memory/' "$DOCKERFILE"
}

@test "Dockerfile validates the rendered config before shipping it" {
  grep -qF 'chmod 0644 /etc/opencode/opencode.json' "$DOCKERFILE"
  grep -qF "jq -e '.mcp | length == 8' /etc/opencode/opencode.json" "$DOCKERFILE"
  grep -qF 'has("context7") or has("grep_app") or has("lsp")' "$DOCKERFILE"
  grep -qF "jq -e 'has(\"plugin\") | not' /etc/opencode/opencode.json" "$DOCKERFILE"
}
