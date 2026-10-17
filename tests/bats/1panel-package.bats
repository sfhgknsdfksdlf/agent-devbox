#!/usr/bin/env bats
# 1Panel local app package: on-disk format + compose <-> data.yml consistency.
# Format verified against 1Panel source: the app root needs data.yml + logo.png,
# and each version subdirectory needs docker-compose.yml (hyphen) + data.yml.

setup() {
  export APP="$BATS_TEST_DIRNAME/../../1panel/agent-devbox"
}

@test "app root has data.yml and logo.png" {
  [ -f "$APP/data.yml" ]
  [ -f "$APP/logo.png" ]
}

@test "latest version dir has docker-compose.yml and data.yml" {
  [ -f "$APP/latest/docker-compose.yml" ]
  [ -f "$APP/latest/data.yml" ]
}

@test "compose env vars are all declared in version data.yml (except CONTAINER_NAME)" {
  if command -v python3 >/dev/null 2>&1; then
    run python3 - "$APP" <<'PY'
import os
import re
import sys

import yaml

root = sys.argv[1]
compose = os.path.join(root, "latest", "docker-compose.yml")
version_data = os.path.join(root, "latest", "data.yml")

fields = yaml.safe_load(open(version_data))["additionalProperties"]["formFields"]
envkeys = [f["envKey"] for f in fields]

for key in envkeys:
    assert " " not in key, "envKey contains a space: %r" % key

text = open(compose).read()
used = set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", text))
undeclared = used - set(envkeys) - {"CONTAINER_NAME"}
assert not undeclared, "undeclared env vars in compose: %s" % sorted(undeclared)

assert "PANEL_APP_PORT_HTTP" in envkeys, "port field must use envKey PANEL_APP_PORT_HTTP"
assert "${PANEL_APP_PORT_HTTP}" in text, "compose ports must reference ${PANEL_APP_PORT_HTTP}"
print("ok")
PY
    [ "$status" -eq 0 ]
    return
  fi

  # bats/bats:latest (Alpine) ships no python3; enforce the same invariants with
  # POSIX tools (awk/grep/sed) so the required docker invocation still verifies.
  local compose="$APP/latest/docker-compose.yml"
  local data="$APP/latest/data.yml"
  [ -f "$compose" ]
  [ -f "$data" ]

  local envkeys used
  envkeys="$(awk -F'envKey:' '/^[[:space:]]*envKey:/ {v=$2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v}' "$data")"
  used="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$compose" | sed -E 's/^\$\{//; s/\}$//' | sort -u)"

  local k v
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    [[ "$k" != *" "* ]] || { echo "envKey contains a space: $k"; return 1; }
  done <<< "$envkeys"

  printf '%s\n' "$envkeys" | grep -Fxq "PANEL_APP_PORT_HTTP" || { echo "missing PANEL_APP_PORT_HTTP envKey"; return 1; }
  grep -q '\${PANEL_APP_PORT_HTTP}' "$compose" || { echo "compose must reference \${PANEL_APP_PORT_HTTP}"; return 1; }

  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [ "$v" = "CONTAINER_NAME" ] && continue
    printf '%s\n' "$envkeys" | grep -Fxq "$v" || { echo "undeclared env var in compose: $v"; return 1; }
  done <<< "$used"
}
