#!/usr/bin/env bats
# P1-2: build state is maintained from what was actually installed.
#
# Offline: every scenario uses tests/fixtures/version-state or a temporary
# manifest. No npm/PyPI/network call, no docker build.
#
# Scenarios (Oracle-corrected scenario 5):
#   1  no drift                       -> changed=false reason=none
#   2  tracked floating drift         -> changed=true upstream-change + key
#   3  query error / upstream missing  -> changed=true fail-open, exit 0
#   4  28-day staleness               -> changed=true reason=stale
#   5  merge records installed 1.2.3; next upstream 1.2.4 -> changed=true
#   6  amd64/arm64 keep their own installed values
#   6d same arch twice                -> exit 2 DUPLICATE_ARCH, out untouched

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  SCRIPT="$REPO_ROOT/.github/scripts/version-state.sh"
  FIX="$REPO_ROOT/tests/fixtures/version-state"
  TMP="$(mktemp -d)"
  export TMP
}

teardown() {
  rm -rf "$TMP"
}

@test "sc1: matching state reports exactly changed=false + reason=none" {
  run "$SCRIPT" --emit changed --manifest "$FIX/sc1/manifest.json" \
    --fixture-dir "$FIX/sc1" --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "changed=false" ]
  [ "${lines[1]}" = "reason=none" ]
}

@test "sc2: one tracked floating drift reports changed=true and the key" {
  run "$SCRIPT" --emit changed --manifest "$FIX/sc2/manifest.json" \
    --fixture-dir "$FIX/sc2" --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=upstream-change" ]
  [ "${lines[2]}" = "changed-key=npm:opencode-ai" ]
  [ "${lines[3]}" = "changed-tool=opencode-ai" ]
}

@test "sc3: failed query fails open with reason=query-error, exit 0" {
  run "$SCRIPT" --emit changed --manifest "$FIX/sc3/manifest.json" \
    --upstream "$FIX/sc3/upstream-query-error.json" --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=query-error" ]
  [ "${lines[2]}" = "changed-key=npm:opencode-ai" ]
}

@test "sc3: missing upstream entry fails open with reason=missing-key, exit 0" {
  run "$SCRIPT" --emit changed --manifest "$FIX/sc3/manifest.json" \
    --upstream "$FIX/sc3/upstream-missing.json" --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=missing-key" ]
  [ "${lines[2]}" = "changed-key=npm:opencode-ai" ]
}

@test "sc4: 28-day staleness reports changed=true reason=stale" {
  run "$SCRIPT" --emit changed --manifest "$FIX/sc4/manifest.json" \
    --fixture-dir "$FIX/sc4" --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=stale" ]
}

@test "sc5: merge records installed 1.2.3 and the next upstream 1.2.4 is drift" {
  MERGED="$TMP/m5.json"
  run "$SCRIPT" merge --build-dir "$FIX/sc5" --out "$MERGED"
  [ "$status" -eq 0 ]
  jq -e '.tools.foo.amd64 == "1.2.3" and .tools.foo.arm64 == "1.2.3"' "$MERGED"
  jq -e '.floating.foo.track == true' "$MERGED"
  jq -e '.fixed["tool:playwright"].version == "1.64.1"' "$MERGED"
  jq -e '.last_built == "2026-11-20T00:05:00Z"' "$MERGED"
  jq -e '.packages.dpkg.amd64.libc6 == "2.41-12"' "$MERGED"
  jq -e '.packages.dpkg.arm64.libc6 == "2.41-12"' "$MERGED"

  run "$SCRIPT" --emit changed --manifest "$MERGED" \
    --upstream "$FIX/sc5/upstream.json" --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=upstream-change" ]
  [ "${lines[2]}" = "changed-key=foo" ]
  [ "${lines[3]}" = "changed-tool=foo" ]

  run "$SCRIPT" --emit changed --manifest "$MERGED" \
    --upstream "$FIX/sc5/upstream-current.json" --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=false" ]
  [ "${lines[1]}" = "reason=none" ]
}

@test "sc6: amd64 and arm64 installed versions never overwrite each other" {
  MERGED="$TMP/m6.json"
  run "$SCRIPT" merge --build-dir "$FIX/sc6" --out "$MERGED"
  [ "$status" -eq 0 ]
  jq -e '.tools.foo.amd64 == "1.2.3"' "$MERGED"
  jq -e '.tools.foo.arm64 == "1.2.4"' "$MERGED"
}

@test "sc6dup: duplicate arch exits 2 with DUPLICATE_ARCH and creates no output" {
  OUT="$TMP/m6dup.json"
  run "$SCRIPT" merge --build-dir "$FIX/sc6dup" --out "$OUT"
  [ "$status" -eq 2 ]
  [ "$output" = "DUPLICATE_ARCH=amd64" ]
  [ ! -e "$OUT" ]
}

@test "sc6dup: duplicate arch never overwrites an existing output file" {
  OUT="$TMP/sentinel.json"
  printf 'SENTINEL\n' >"$OUT"
  run "$SCRIPT" merge --build-dir "$FIX/sc6dup" --out "$OUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"DUPLICATE_ARCH=amd64"* ]]
  [ "$(cat "$OUT")" = "SENTINEL" ]
}

@test "structural: --emit manifest prints normalized v2 JSON for the seed" {
  run "$SCRIPT" --emit manifest --manifest "$REPO_ROOT/versions.json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.schemaVersion == 2' >/dev/null
  printf '%s' "$output" | jq -e '(.floating | length) == 19' >/dev/null
  printf '%s' "$output" | jq -e '.floating["npm:@getpaseo/cli"].package == "@getpaseo/cli"' >/dev/null
  printf '%s' "$output" | jq -e '.floating["pypi:aider-chat"].ecosystem == "pypi"' >/dev/null
  printf '%s' "$output" | jq -e '.floating["npm:open-websearch"].package == "open-websearch"' >/dev/null
  printf '%s' "$output" | jq -e '.floating["npm:shadcn"].package == "shadcn"' >/dev/null
  printf '%s' "$output" | jq -e '.floating["npm:@playwright/mcp"].package == "@playwright/mcp"' >/dev/null
  printf '%s' "$output" | jq -e '.fixed["tool:mcp-memory-service"] == {"kind":"pypi","version":"13.0.0"}' >/dev/null
  printf '%s' "$output" | jq -e '.fixed["tool:mcp-dap-server"] == {"kind":"go-module","version":"v0.0.0-20261103230859-6011c2cd13e8"}' >/dev/null
  printf '%s' "$output" | jq -e '.fixed["base:node"].digest == "sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0"' >/dev/null
  printf '%s' "$output" | jq -e '.fixed["image:core"].digest == "sha256:6c295e41755ead3667779650473515bf70ddd8096e8ad8a4af4d488026c127b9"' >/dev/null
  printf '%s' "$output" | jq -e '(.tools | length) == 0 and (.packages.dpkg | length) == 0 and .last_built == null' >/dev/null
}

@test "structural: a legacy flat manifest migrates to v2 only" {
  V1="$TMP/v1.json"
  printf '{"opencode-ai":"1.19.5","aider-chat":"0.86.2","_comment":"legacy"}\n' >"$V1"
  run "$SCRIPT" --emit manifest --manifest "$V1"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.schemaVersion == 2' >/dev/null
  printf '%s' "$output" | jq -e '.floating["npm:opencode-ai"].package == "opencode-ai"' >/dev/null
  printf '%s' "$output" | jq -e '.floating["pypi:aider-chat"].ecosystem == "pypi"' >/dev/null
  printf '%s' "$output" | jq -e '(.tools | length) == 0 and .last_built == null' >/dev/null
  printf '%s' "$output" | jq -e 'has("opencode-ai") | not' >/dev/null
}

@test "structural: damaged manifest exits 1 and emits no v2 JSON" {
  BAD="$TMP/bad.json"
  printf '{not json\n' >"$BAD"
  run "$SCRIPT" --emit manifest --manifest "$BAD"
  [ "$status" -eq 1 ]
  [[ "$output" != *'"schemaVersion"'* ]]
}

@test "structural: unknown or incomplete arguments exit 2" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPT" --manifest "$FIX/sc1/manifest.json"
  [ "$status" -eq 2 ]
  run "$SCRIPT" merge --build-dir "$FIX/sc6"
  [ "$status" -eq 2 ]
  run "$SCRIPT" --emit changed --manifest "$FIX/sc1/manifest.json" --now not-a-date
  [ "$status" -eq 2 ]
}

@test "structural: changed keys are emitted sorted and only track=true is compared" {
  MANIFEST="$TMP/multi.json"
  UPSTREAM="$TMP/multi-upstream.json"
  cat >"$MANIFEST" <<'JSON'
{
  "schemaVersion": 2,
  "floating": {
    "npm:zeta": {"ecosystem": "npm", "package": "zeta", "track": true},
    "npm:alpha": {"ecosystem": "npm", "package": "alpha", "track": true},
    "pypi:beta": {"ecosystem": "pypi", "package": "beta", "track": true},
    "npm:ignored": {"ecosystem": "npm", "package": "ignored", "track": false}
  },
  "fixed": {},
  "tools": {
    "zeta": {"amd64": "1.0.0", "arm64": "1.0.0"},
    "alpha": {"amd64": "1.0.0", "arm64": "1.0.0"},
    "beta": {"amd64": "1.0.0", "arm64": "1.0.0"},
    "ignored": {"amd64": "1.0.0", "arm64": "1.0.0"}
  },
  "packages": {"dpkg": {}},
  "last_built": "2026-11-20T00:00:00Z"
}
JSON
  cat >"$UPSTREAM" <<'JSON'
{"npm:zeta":"2.0.0","npm:alpha":"2.0.0","pypi:beta":"2.0.0","npm:ignored":"9.9.9"}
JSON
  run "$SCRIPT" --emit changed --manifest "$MANIFEST" --upstream "$UPSTREAM" \
    --now 2026-11-23T00:00:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=upstream-change" ]
  [ "${lines[2]}" = "changed-key=npm:alpha" ]
  [ "${lines[4]}" = "changed-key=npm:zeta" ]
  [ "${lines[6]}" = "changed-key=pypi:beta" ]
  [[ "$output" != *"changed-key=npm:ignored"* ]]
}

@test "structural: missing tools/last_built fail open, future/invalid last_built exit 1" {
  NO_TOOL="$TMP/no-tool.json"
  NO_LB="$TMP/no-lb.json"
  FUTURE="$TMP/future.json"
  INVALID="$TMP/invalid-lb.json"
  jq '.tools |= del(."opencode-ai")' "$FIX/sc1/manifest.json" >"$NO_TOOL"
  jq 'del(.last_built)' "$FIX/sc1/manifest.json" >"$NO_LB"
  jq '.last_built = "2026-12-01T00:00:00Z"' "$FIX/sc1/manifest.json" >"$FUTURE"
  jq '.last_built = "yesterday"' "$FIX/sc1/manifest.json" >"$INVALID"

  run "$SCRIPT" --emit changed --manifest "$NO_TOOL" --fixture-dir "$FIX/sc1" \
    --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=missing-key" ]

  run "$SCRIPT" --emit changed --manifest "$NO_LB" --fixture-dir "$FIX/sc1" \
    --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=missing-key" ]

  run "$SCRIPT" --emit changed --manifest "$FUTURE" --fixture-dir "$FIX/sc1" \
    --now 2026-11-23T03:23:00Z
  [ "$status" -eq 1 ]

  run "$SCRIPT" --emit changed --manifest "$INVALID" --fixture-dir "$FIX/sc1" \
    --now 2026-11-23T03:23:00Z
  [ "$status" -eq 1 ]
}

@test "structural: --fixture-dir defaults the manifest and an explicit --upstream wins" {
  run "$SCRIPT" --emit changed --fixture-dir "$FIX/sc1" --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=false" ]

  run "$SCRIPT" --emit changed --manifest "$FIX/sc3/manifest.json" \
    --fixture-dir "$FIX/sc1" --upstream "$FIX/sc2/upstream.json" \
    --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=upstream-change" ]
}

@test "structural: invalid v2 schema exits 1 and a legacy flat manifest fails open" {
  BAD_SCHEMA="$TMP/bad-schema.json"
  V1="$TMP/legacy.json"
  printf '{"schemaVersion":2,"floating":[],"fixed":{},"tools":{},"packages":{"dpkg":{}},"last_built":null}\n' >"$BAD_SCHEMA"
  run "$SCRIPT" --emit manifest --manifest "$BAD_SCHEMA"
  [ "$status" -eq 1 ]

  printf '{"opencode-ai":"1.19.5","aider-chat":"0.86.2"}\n' >"$V1"
  run "$SCRIPT" --emit changed --manifest "$V1" --upstream "$FIX/sc1/upstream.json" \
    --now 2026-11-23T03:23:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=missing-key" ]
}

@test "structural: merge rejects an invalid base manifest before writing --out" {
  BAD_BASE="$TMP/bad-base.json"
  OUT="$TMP/bad-base-out.json"
  printf '{broken\n' >"$BAD_BASE"
  run "$SCRIPT" merge --build-dir "$FIX/sc6" --manifest "$BAD_BASE" --out "$OUT"
  [ "$status" -eq 1 ]
  [ ! -e "$OUT" ]
}

@test "structural: merge rejects an invalid built_at or arch" {
  DIR="$TMP/case"
  mkdir -p "$DIR"
  jq '.built_at = "not-a-date"' "$FIX/sc6/build-amd64.json" >"$DIR/build-amd64.json"
  run "$SCRIPT" merge --build-dir "$DIR" --out "$TMP/never.json"
  [ "$status" -eq 1 ]
  [ ! -e "$TMP/never.json" ]

  jq '.arch = "riscv64"' "$FIX/sc6/build-amd64.json" >"$DIR/build-amd64.json"
  run "$SCRIPT" merge --build-dir "$DIR" --out "$TMP/never2.json"
  [ "$status" -eq 1 ]
  [ ! -e "$TMP/never2.json" ]
}

@test "structural: --emit manifest defaults to the repo-root versions.json" {
  cd "$TMP"
  run "$SCRIPT" --emit manifest
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.schemaVersion == 2 and (.floating | length) == 19' >/dev/null
}

@test "structural: scoped npm floating key survives the tab protocol and is compared by package" {
  MANIFEST="$TMP/scoped.json"
  UPSTREAM="$TMP/scoped-upstream.json"
  cat >"$MANIFEST" <<'JSON'
{
  "schemaVersion": 2,
  "floating": {
    "npm:@playwright/mcp": {"ecosystem": "npm", "package": "@playwright/mcp", "track": true}
  },
  "fixed": {},
  "tools": {
    "@playwright/mcp": {"amd64": "0.0.86", "arm64": "0.0.86"}
  },
  "packages": {"dpkg": {}},
  "last_built": "2026-11-20T00:00:00Z"
}
JSON
  printf '{"npm:@playwright/mcp":"0.0.86"}\n' >"$UPSTREAM"
  run "$SCRIPT" --emit changed --manifest "$MANIFEST" --upstream "$UPSTREAM" \
    --now 2026-11-23T00:00:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=false" ]
  [ "${lines[1]}" = "reason=none" ]

  printf '{"npm:@playwright/mcp":"0.0.87"}\n' >"$UPSTREAM"
  run "$SCRIPT" --emit changed --manifest "$MANIFEST" --upstream "$UPSTREAM" \
    --now 2026-11-23T00:00:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=true" ]
  [ "${lines[1]}" = "reason=upstream-change" ]
  [ "${lines[2]}" = "changed-key=npm:@playwright/mcp" ]
  [ "${lines[3]}" = "changed-tool=@playwright/mcp" ]
}

@test "structural: MCP fixed pins merge through and are never compared" {
  MANIFEST="$TMP/mcp-fixed.json"
  UPSTREAM="$TMP/mcp-fixed-upstream.json"
  MERGED="$TMP/mcp-fixed-merged.json"
  cat >"$MANIFEST" <<'JSON'
{
  "schemaVersion": 2,
  "floating": {
    "npm:zeta": {"ecosystem": "npm", "package": "zeta", "track": true}
  },
  "fixed": {
    "tool:mcp-memory-service": {"kind": "pypi", "version": "13.0.0"},
    "tool:mcp-dap-server": {"kind": "go-module", "version": "v0.0.0-20261103230859-6011c2cd13e8"}
  },
  "tools": {
    "zeta": {"amd64": "1.0.0", "arm64": "1.0.0"}
  },
  "packages": {"dpkg": {}},
  "last_built": "2026-11-20T00:00:00Z"
}
JSON
  printf '{"npm:zeta":"1.0.0"}\n' >"$UPSTREAM"

  run "$SCRIPT" --emit changed --manifest "$MANIFEST" --upstream "$UPSTREAM" \
    --now 2026-11-23T00:00:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "changed=false" ]
  [ "${lines[1]}" = "reason=none" ]

  run "$SCRIPT" --emit manifest --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .fixed["tool:mcp-memory-service"] == {"kind": "pypi", "version": "13.0.0"}
    and .fixed["tool:mcp-dap-server"] == {"kind": "go-module", "version": "v0.0.0-20261103230859-6011c2cd13e8"}
  ' >/dev/null

  run "$SCRIPT" merge --build-dir "$FIX/sc5" --manifest "$MANIFEST" --out "$MERGED"
  [ "$status" -eq 0 ]
  jq -e '
    .fixed["tool:mcp-memory-service"].version == "13.0.0"
    and .fixed["tool:mcp-dap-server"].version == "v0.0.0-20261103230859-6011c2cd13e8"
    and .floating["npm:zeta"].track == true
  ' "$MERGED"
}
