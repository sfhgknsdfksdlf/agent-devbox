#!/usr/bin/env bats
# P1-1: third-party image assets are pinned AND byte-verified before use.
#
# Offline: no network, no docker build, no registry access. The tests exercise
# scripts/image-assets.sh for real (temporary manifests/files) and execute the
# actual Dockerfile RUN blocks with stubbed download/extract/install commands,
# so a policy revert (unpinned base, floating marksman, unverified uv/Go,
# amd64 fallback, ignored manifest hash) makes them fail.

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  SCRIPT="$REPO_ROOT/scripts/image-assets.sh"
  MANIFEST="$REPO_ROOT/config/image-assets.sha256"
  DOCKERFILE="$REPO_ROOT/Dockerfile"
  AGENTS_DOCKERFILE="$REPO_ROOT/Dockerfile.agents"
  WSL_DOCKERFILE="$REPO_ROOT/Dockerfile.wsl"
  BUILD_WORKFLOW="$REPO_ROOT/.github/workflows/build.yml"
  BUMP_WORKFLOW="$REPO_ROOT/.github/workflows/bump-pinned.yml"

  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin" "$TMP/work"
  export TMP
}

teardown() {
  rm -rf "$TMP"
}

# Deterministic 64-char lower-case hex values.
sha_for() {
  printf '%064x' "$1"
}

sha256_of() {
  local out
  out="$(sha256sum -- "$1")"
  printf '%s\n' "${out%% *}"
}

write_valid_manifest() {
  local f="$1"
  {
    printf 'version\tfilename\tarch\tsha256\n'
    printf '1.0.0\t%s\tamd64\t%s\n' 'tool-a-amd64.tar.gz' "$(sha_for 1)"
    printf '1.0.0\t%s\tarm64\t%s\n' 'tool-a-arm64.tar.gz' "$(sha_for 2)"
    printf '1.0.0\t%s\tamd64\t%s\n' 'dual.tar.gz' "$(sha_for 3)"
    printf '1.0.0\t%s\tarm64\t%s\n' 'dual.tar.gz' "$(sha_for 4)"
  } > "$f"
}

write_mixed_manifest() {
  local f="$1"
  {
    printf 'version\tfilename\tarch\tsha256\n'
    printf '0.13.9\t%s\tamd64\t%s\n' 'uv-x86_64-unknown-linux-gnu.tar.gz' "$(sha_for 21)"
    printf '1.27.2\t%s\tamd64\t%s\n' 'go1.27.2.linux-amd64.tar.gz' "$(sha_for 22)"
    printf '1.27.2\t%s\tarm64\t%s\n' 'go1.27.2.linux-arm64.tar.gz' "$(sha_for 23)"
    printf '2026-02-08\t%s\tamd64\t%s\n' 'marksman-linux-x64' "$(sha_for 24)"
    printf '7.6.7\t%s\tamd64\t%s\n' 'powershell_7.6.7-1.deb_amd64.deb' "$(sha_for 25)"
  } > "$f"
}

index_of() {
  awk -v s="$1" -v t="$2" 'BEGIN { print index(s, t) }'
}

# Join Dockerfile backslash continuations so each RUN is one testable line.
logical_runs() {
  awk '
    {
      trimmed = $0
      sub(/[[:space:]]+$/, "", trimmed)
      if (buf == "") { buf = trimmed } else { buf = buf " " trimmed }
      if (trimmed ~ /\\$/) { sub(/\\$/, "", buf) }
      else { print buf; buf = "" }
    }
    END { if (buf != "") print buf }
  ' "$1"
}

# Print the joined RUN line that contains <marker>.
run_line() {
  logical_runs "$1" | grep -F -- "$2"
}

install_stubs() {
  cat > "$TMP/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--print-architecture" ] || exit 2
printf '%s\n' "${STUB_ARCH:?}"
EOF

  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --retry|--retry-delay) shift 2 ;;
    --retry-all-errors|-fsSL|-fsS) shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ -n "$out" ] || { echo "curl stub: missing -o" >&2; exit 2; }
cp -- "${STUB_ASSET:?}" "$out"
printf 'curl %s\n' "$url" >> "${STUB_LOG:?}"
EOF

  cat > "$TMP/bin/tar" <<'EOF'
#!/usr/bin/env bash
printf 'tar %s\n' "$*" >> "${STUB_LOG:?}"
EOF

  cat > "$TMP/bin/install" <<'EOF'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >> "${STUB_LOG:?}"
EOF

  cat > "$TMP/bin/ln" <<'EOF'
#!/usr/bin/env bash
printf 'ln %s\n' "$*" >> "${STUB_LOG:?}"
EOF

  cat > "$TMP/bin/go" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  version) printf 'go version go%s linux/amd64\n' "${STUB_GO_VERSION:-1.27.2}" ;;
  env) printf '%s\n' "${STUB_GOSUMDB:-sum.golang.org}" ;;
  *) exit 2 ;;
esac
EOF

  cat > "$TMP/bin/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv %s\n' "${STUB_UV_VERSION:-0.13.9}"
EOF

  cat > "$TMP/bin/uvx" <<'EOF'
#!/usr/bin/env bash
printf 'uvx %s\n' "${STUB_UV_VERSION:-0.13.9}"
EOF

  chmod 0755 "$TMP/bin/"*
  ln -sf "$SCRIPT" "$TMP/bin/image-assets"
}

# Execute a real Dockerfile RUN block in the stub sandbox. /tmp is redirected
# into the test dir and the manifest path is swapped so nothing outside TMP is
# read or written.
exec_block() {
  local dockerfile="$1" marker="$2" manifest="$3" line cmd
  line="$(run_line "$dockerfile" "$marker")"
  [ -n "$line" ] || { echo "no RUN block contains: $marker" >&2; return 1; }
  cmd="${line#RUN }"
  cmd="$(printf '%s\n' "$cmd" \
    | sed -e "s|/tmp/|$TMP/work/|g" \
          -e "s|/usr/local/share/agent-devbox/image-assets.sha256|$manifest|g")"

  export UV_VERSION
  UV_VERSION="$(sed -n 's/^ARG UV_VERSION=//p' "$DOCKERFILE" | head -1)"
  export GO_VERSION
  GO_VERSION="$(sed -n 's/^ARG GO_VERSION=//p' "$DOCKERFILE" | head -1)"
  export POWERSHELL_VERSION
  POWERSHELL_VERSION="$(sed -n 's/^ARG POWERSHELL_VERSION=//p' "$WSL_DOCKERFILE" | head -1)"

  PATH="$TMP/bin:$PATH" bash -euc "$cmd"
}

@test "the checked-in manifest is valid and has 8 verified entries" {
  run "$SCRIPT" verify-manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"manifest ok (8 entries)"* ]]

  # Exact UTF-8/LF/no-BOM header; no CR and no BOM allowed.
  [ "$(head -c 3 "$MANIFEST" | od -An -tx1 | tr -d ' \n')" != "efbbbf" ]
  run grep -q $'\r' "$MANIFEST"
  [ "$status" -ne 0 ]

  # Checksum files are inputs, never manifest rows.
  run awk -F'\t' 'NR > 1 && tolower($2) ~ /(sha256|sums?|\.sig|\.txt)$/ { print; found = 1 } END { exit(found ? 0 : 1) }' "$MANIFEST"
  [ "$status" -ne 0 ]
}

@test "valid manifest passes and counts 4 entries" {
  write_valid_manifest "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -eq 0 ]
  [[ "$output" == *"4 entries"* ]]
}

@test "same filename+version on different arches is accepted" {
  write_valid_manifest "$TMP/m"
  grep -qF $'1.0.0\tdual.tar.gz\tamd64' "$TMP/m"
  grep -qF $'1.0.0\tdual.tar.gz\tarm64' "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -eq 0 ]
}

@test "duplicate (version, filename, arch) is rejected, even with the same hash" {
  write_valid_manifest "$TMP/m"
  printf '1.0.0\t%s\tamd64\t%s\n' 'dual.tar.gz' "$(sha_for 3)" >> "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "malformed headers are rejected (spaces, BOM, missing column)" {
  printf 'version filename arch sha256\n1.0.0\ta\tamd64\t%s\n' "$(sha_for 1)" > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid header"* ]]

  {
    printf '\357\273\277'
    printf 'version\tfilename\tarch\tsha256\n1.0.0\ta\tamd64\t%s\n' "$(sha_for 1)"
  } > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid header"* ]]
}

@test "malformed rows are rejected (3/5 columns, empty field, CRLF, blank line)" {
  local good
  good="$(sha_for 1)"

  printf 'version\tfilename\tarch\tsha256\n1.0.0\ta\tamd64\n' > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed row"* ]]

  printf 'version\tfilename\tarch\tsha256\n1.0.0\ta\tamd64\t%s\textra\n' "$good" > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed row"* ]]

  printf 'version\tfilename\tarch\tsha256\n1.0.0\t\tamd64\t%s\n' "$good" > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be empty"* ]]

  printf 'version\tfilename\tarch\tsha256\r\n1.0.0\ta\tamd64\t%s\r\n' "$good" > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]

  printf 'version\tfilename\tarch\tsha256\n\n1.0.0\ta\tamd64\t%s\n' "$good" > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blank row"* ]]
}

@test "malformed arch and sha256 are rejected" {
  printf 'version\tfilename\tarch\tsha256\n1.0.0\ta\tx86_64\t%s\n' "$(sha_for 1)" > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported architecture"* ]]

  printf 'version\tfilename\tarch\tsha256\n1.0.0\ta\tAMD64\t%s\n' "$(sha_for 1)" > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]

  printf 'version\tfilename\tarch\tsha256\n1.0.0\ta\tamd64\t%s\n' "$(sha_for 10 | tr 'a-f' 'A-F')" > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid sha256"* ]]

  printf 'version\tfilename\tarch\tsha256\n1.0.0\ta\tamd64\t%s\n' "$(sha_for 1 | cut -c1-63)" > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]

  printf 'version\tfilename\tarch\tsha256\n' > "$TMP/m"
  run "$SCRIPT" verify-manifest "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no data rows"* ]]
}

@test "verify-file accepts the exact bytes and rejects wrong bytes/hash" {
  local asset="$TMP/asset"
  printf 'payload-A\n' > "$asset"
  printf 'version\tfilename\tarch\tsha256\n' > "$TMP/m"
  printf '1.0.0\ttool.tar.gz\tamd64\t%s\n' "$(sha256_of "$asset")" >> "$TMP/m"

  run "$SCRIPT" verify-file "$TMP/m" 1.0.0 tool.tar.gz amd64 "$asset"
  [ "$status" -eq 0 ]

  # Wrong bytes under the right name: the recorded hash must not match.
  printf 'payload-B\n' > "$asset"
  run "$SCRIPT" verify-file "$TMP/m" 1.0.0 tool.tar.gz amd64 "$asset"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256 mismatch"* ]]

  # The target is read-only: verification failure must not modify it.
  [ "$(cat "$asset")" = "payload-B" ]

  run "$SCRIPT" verify-file "$TMP/m" 2.0.0 tool.tar.gz amd64 "$asset"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no manifest entry"* ]]

  run "$SCRIPT" verify-file "$TMP/m" 1.0.0 tool.tar.gz arm64 "$asset"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no manifest entry"* ]]

  run "$SCRIPT" verify-file "$TMP/m" 1.0.0 tool.tar.gz amd64 "$TMP/missing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"file not found"* ]]
}

@test "asset-name maps amd64/arm64 exactly and never falls back" {
  [ "$("$SCRIPT" asset-name marksman amd64)" = "marksman-linux-x64" ]
  [ "$("$SCRIPT" asset-name marksman arm64)" = "marksman-linux-arm64" ]
  [ "$("$SCRIPT" asset-name uv amd64)" = "uv-x86_64-unknown-linux-gnu.tar.gz" ]
  [ "$("$SCRIPT" asset-name uv arm64)" = "uv-aarch64-unknown-linux-gnu.tar.gz" ]
  [ "$("$SCRIPT" asset-name go amd64)" = "amd64" ]
  [ "$("$SCRIPT" asset-name go arm64)" = "arm64" ]
  [ "$("$SCRIPT" asset-name powershell amd64 7.6.7)" = "powershell_7.6.7-1.deb_amd64.deb" ]
  [ "$("$SCRIPT" asset-name powershell arm64 7.6.7)" = "powershell_7.6.7-1.deb_arm64.deb" ]

  local out status_code
  for arch in riscv64 x86_64 '' ARM64; do
    status_code=0
    out="$("$SCRIPT" asset-name uv "$arch" 2>/dev/null)" || status_code=$?
    [ "$status_code" -ne 0 ]
    [ -z "$out" ]
  done
}

@test "PowerShell UTF-16LE+CRLF hashes.sha256: exact Debian basename is parsed" {
  local fixture="$TMP/pwsh.hashes.sha256"
  local amd_hash arm_hash lts_hash
  amd_hash="$(sha_for 31)"
  arm_hash="$(sha_for 32)"
  lts_hash="$(sha_for 33)"

  {
    printf '%s *powershell-lts_7.6.7-1.deb_amd64.deb\r\n' "$lts_hash"
    printf '%s *powershell-lts_7.6.7-1.deb_arm64.deb\r\n' "$(sha_for 34)"
    printf '%s *powershell_7.6.7-1.deb_amd64.deb\r\n' "$amd_hash"
    printf '%s *powershell_7.6.7-1.deb_arm64.deb\r\n' "$arm_hash"
    printf '%s *powershell_7.6.7-linux-x64.tar.gz\r\n' "$(sha_for 35)"
  } | iconv -f UTF-8 -t UTF-16LE > "$TMP/pwsh.body"
  {
    printf '\377\376'
    cat "$TMP/pwsh.body"
  } > "$fixture"

  # Really UTF-16LE with a BOM.
  [ "$(head -c 2 "$fixture" | od -An -tx1 | tr -d ' \n')" = "fffe" ]

  # NUL-interleaved UTF-16 means the plain-text line is not present as-is;
  # only the explicit UTF-16 decode yields a parsable sha256sum line.
  run grep -qF "$amd_hash *powershell_7.6.7-1.deb_amd64.deb" "$fixture"
  [ "$status" -ne 0 ]

  iconv -f UTF-16 -t UTF-8 "$fixture" | tr -d '\r' > "$TMP/hashes.txt"
  grep -qF "$amd_hash *powershell_7.6.7-1.deb_amd64.deb" "$TMP/hashes.txt"
  run grep -q $'\r' "$TMP/hashes.txt"
  [ "$status" -ne 0 ]

  [ "$("$SCRIPT" sha-from-sums "$TMP/hashes.txt" powershell_7.6.7-1.deb_amd64.deb)" = "$amd_hash" ]
  [ "$("$SCRIPT" sha-from-sums "$TMP/hashes.txt" powershell_7.6.7-1.deb_arm64.deb)" = "$arm_hash" ]
  # The LTS decoy keeps its own hash: the match is exact, not a substring.
  [ "$("$SCRIPT" sha-from-sums "$TMP/hashes.txt" powershell-lts_7.6.7-1.deb_amd64.deb)" = "$lts_hash" ]

  run "$SCRIPT" sha-from-sums "$TMP/hashes.txt" powershell_7.6.7-1.deb_riscv64.deb
  [ "$status" -ne 0 ]

  printf '%s *powershell_7.6.7-1.deb_amd64.deb\r\n' "$(sha_for 36)" >> "$TMP/hashes.txt"
  run "$SCRIPT" sha-from-sums "$TMP/hashes.txt" powershell_7.6.7-1.deb_amd64.deb
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one"* ]]
}

@test "update-go replaces both Go rows atomically and preserves other tools" {
  local f="$TMP/m" before_mode
  write_mixed_manifest "$f"
  chmod 0644 "$f"

  run "$SCRIPT" update-go "$f" 1.27.4 "$(sha_for 41)" "$(sha_for 42)"
  [ "$status" -eq 0 ]

  [ "$(grep -cF $'1.27.4\tgo1.27.4.linux-amd64.tar.gz\tamd64' "$f")" -eq 1 ]
  [ "$(grep -cF $'1.27.4\tgo1.27.4.linux-arm64.tar.gz\tarm64' "$f")" -eq 1 ]
  grep -qF "$(sha_for 41)" "$f"
  grep -qF "$(sha_for 42)" "$f"
  run grep -q 'go1.27.2' "$f"
  [ "$status" -ne 0 ]

  # Exactly two Go rows, no duplicates after a second run (idempotent).
  run "$SCRIPT" update-go "$f" 1.27.4 "$(sha_for 41)" "$(sha_for 42)"
  [ "$status" -eq 0 ]
  [ "$(grep -cE $'\tgo[0-9].*\\.linux-(amd64|arm64)\\.tar\\.gz\t' "$f")" -eq 2 ]

  # uv/marksman/PowerShell rows are byte-identical.
  grep -qF "$(printf '0.13.9\t%s\tamd64\t%s' 'uv-x86_64-unknown-linux-gnu.tar.gz' "$(sha_for 21)")" "$f"
  grep -qF "$(printf '2026-02-08\t%s\tamd64\t%s' 'marksman-linux-x64' "$(sha_for 24)")" "$f"
  grep -qF "$(printf '7.6.7\t%s\tamd64\t%s' 'powershell_7.6.7-1.deb_amd64.deb' "$(sha_for 25)")" "$f"

  run "$SCRIPT" verify-manifest "$f"
  [ "$status" -eq 0 ]

  before_mode="$(stat -c '%a' "$f")"
  [ "$before_mode" = "644" ]
  run ls -A "$TMP"
  [[ "$output" != *".image-assets."* ]]
}

@test "update-go appends both rows when the manifest has no Go rows" {
  local f="$TMP/m"
  {
    printf 'version\tfilename\tarch\tsha256\n'
    printf '0.13.9\t%s\tamd64\t%s\n' 'uv-x86_64-unknown-linux-gnu.tar.gz' "$(sha_for 51)"
  } > "$f"

  run "$SCRIPT" update-go "$f" 1.27.4 "$(sha_for 52)" "$(sha_for 53)"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$f")" -eq 4 ]
  grep -qF $'1.27.4\tgo1.27.4.linux-amd64.tar.gz\tamd64' "$f"
  grep -qF $'1.27.4\tgo1.27.4.linux-arm64.tar.gz\tarm64' "$f"
  run "$SCRIPT" verify-manifest "$f"
  [ "$status" -eq 0 ]
}

@test "update-go fails closed on malformed/missing input and leaves the file untouched" {
  local f="$TMP/m" before after
  write_mixed_manifest "$f"

  before="$(sha256_of "$f")"
  run "$SCRIPT" update-go "$f" 1.27.4 "$(sha_for 61 | cut -c1-63)" "$(sha_for 62)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid amd64 sha256"* ]]

  run "$SCRIPT" update-go "$f" 1.27.4 "$(sha_for 61 | tr 'a-f' 'A-F')" "$(sha_for 62)"
  [ "$status" -ne 0 ]

  run "$SCRIPT" update-go "$f" 1.27.4 "$(sha_for 61)"
  [ "$status" -ne 0 ]

  run "$SCRIPT" update-go "$f" '1.27.4/evil' "$(sha_for 61)" "$(sha_for 62)"
  [ "$status" -ne 0 ]

  after="$(sha256_of "$f")"
  [ "$before" = "$after" ]
  run ls -A "$TMP"
  [[ "$output" != *".image-assets."* ]]
}

@test "Dockerfile pins the Node index digest and keeps exactly one FROM" {
  local from
  from="$(grep -E '^FROM ' "$DOCKERFILE")"
  [ "$(printf '%s\n' "$from" | grep -cE '^FROM ')" -eq 1 ]
  [ "$from" = "FROM node:24-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0" ]

  run grep -qE '^FROM node:24-trixie-slim[[:space:]]*$' "$DOCKERFILE"
  [ "$status" -ne 0 ]
}

@test "Dockerfile never disables the Go checksum DB and checks it at build time" {
  run grep -q 'GOSUMDB=off' "$DOCKERFILE"
  [ "$status" -ne 0 ]
  run grep -q 'GONOSUMDB' "$DOCKERFILE"
  [ "$status" -ne 0 ]
  run grep -q 'GOPROXY=.*off' "$DOCKERFILE"
  [ "$status" -ne 0 ]

  grep -qF 'go env GOSUMDB' "$DOCKERFILE"
  grep -qF '"$sumdb" = "off"' "$DOCKERFILE"
}

@test "Dockerfile.agents default is a readable tag + index digest; CI overrides it" {
  local arg
  arg="$(grep -E '^ARG CORE_IMAGE=' "$AGENTS_DOCKERFILE")"
  [ "$arg" = "ARG CORE_IMAGE=ghcr.io/sfhgknsdfksdlf/agent-devbox-core:latest@sha256:6c295e41755ead3667779650473515bf70ddd8096e8ad8a4af4d488026c127b9" ]
  grep -qF 'FROM ${CORE_IMAGE}' "$AGENTS_DOCKERFILE"

  # The same-run digest override is still the CI path.
  grep -qF 'steps.core.outputs.digest' "$BUILD_WORKFLOW"
}

@test "no frontend image/service pin was added anywhere" {
  local f
  for f in "$MANIFEST" "$DOCKERFILE" "$AGENTS_DOCKERFILE" "$WSL_DOCKERFILE" "$BUMP_WORKFLOW"; do
    # `[^a-z_]` keeps the legitimate DEBIAN_FRONTEND env var out of the match.
    run grep -qiE '(^|[^a-z_])frontend([^a-z_]|$)' "$f"
    [ "$status" -ne 0 ]
  done
}

@test "marksman uses the exact tag (never releases/latest) and pre-install verification" {
  run grep -q 'artempyanykh/marksman/releases/latest' "$DOCKERFILE"
  [ "$status" -ne 0 ]
  grep -qF 'artempyanykh/marksman/releases/download/2026-02-08/${marksman_asset}' "$DOCKERFILE"

  local line verify install_at
  line="$(run_line "$DOCKERFILE" 'artempyanykh/marksman')"
  [ -n "$line" ]
  [[ "$line" == *'set -eux'* ]]
  [[ "$line" != *'|| true'* ]]
  grep -qF 'libicu76' <<< "$line"

  verify="$(index_of "$line" 'image-assets verify-file')"
  install_at="$(index_of "$line" '/usr/local/bin/marksman')"
  [ "$verify" -gt 0 ]
  [ "$install_at" -gt "$verify" ]
}

@test "uv comes from the pinned release archive and is verified before extraction" {
  run grep -q 'astral.sh/uv/install.sh' "$DOCKERFILE"
  [ "$status" -ne 0 ]
  grep -qF 'astral-sh/uv/releases/download/${UV_VERSION}/${uv_asset}' "$DOCKERFILE"
  grep -qE '^ARG UV_VERSION=0\.13\.9$' "$DOCKERFILE"

  local line verify tar_at install_at
  line="$(run_line "$DOCKERFILE" 'astral-sh/uv/releases')"
  [ -n "$line" ]
  [[ "$line" == *'set -eux'* ]]
  [[ "$line" != *'|| true'* ]]

  verify="$(index_of "$line" 'image-assets verify-file')"
  tar_at="$(index_of "$line" 'tar -C /tmp -xzf')"
  install_at="$(index_of "$line" '/usr/local/bin/uv')"
  [ "$verify" -gt 0 ]
  [ "$tar_at" -gt "$verify" ]
  [ "$install_at" -gt "$verify" ]
}

@test "go tarball is verified before extraction" {
  grep -qF 'image-assets asset-name go "$arch"' "$DOCKERFILE"
  grep -qF 'https://go.dev/dl/${go_asset}' "$DOCKERFILE"

  local line verify tar_at
  line="$(run_line "$DOCKERFILE" 'go.dev/dl')"
  [ -n "$line" ]
  [[ "$line" == *'set -eux'* ]]
  [[ "$line" != *'|| true'* ]]

  verify="$(index_of "$line" 'image-assets verify-file')"
  tar_at="$(index_of "$line" 'tar -C /usr/local -xzf')"
  [ "$verify" -gt 0 ]
  [ "$tar_at" -gt "$verify" ]
}

@test "WSL PowerShell block decodes UTF-16 and passes both gates before apt install" {
  grep -qF 'iconv -f UTF-16 -t UTF-8' "$WSL_DOCKERFILE"
  grep -qF "tr -d '\\r'" "$WSL_DOCKERFILE"
  grep -qF 'sha-from-sums' "$WSL_DOCKERFILE"
  grep -qF 'sha256sum -c -' "$WSL_DOCKERFILE"
  grep -qF 'image-assets asset-name powershell "$arch" "$POWERSHELL_VERSION"' "$WSL_DOCKERFILE"
  grep -qF '/usr/local/share/agent-devbox/image-assets.sha256' "$WSL_DOCKERFILE"
  # No base-image pin is added here; the export job supplies BASE_IMAGE.
  grep -qE '^FROM \$\{BASE_IMAGE\}$' "$WSL_DOCKERFILE"
  run grep -qE '^FROM .*@sha256:' "$WSL_DOCKERFILE"
  [ "$status" -ne 0 ]

  local line check_at verify_at install_at
  line="$(run_line "$WSL_DOCKERFILE" '/tmp/powershell.hashes.sha256')"
  [ -n "$line" ]
  [[ "$line" == *'set -eux'* ]]

  check_at="$(index_of "$line" 'sha256sum -c -')"
  verify_at="$(index_of "$line" 'image-assets verify-file')"
  install_at="$(index_of "$line" '--no-install-recommends /tmp/powershell.deb')"
  [ "$check_at" -gt 0 ]
  [ "$verify_at" -gt "$check_at" ]
  [ "$install_at" -gt "$verify_at" ]
}

@test "uv RUN block extracts/installs only after a matching manifest hash (amd64 + arm64)" {
  install_stubs
  export STUB_LOG="$TMP/stubs.log" STUB_ASSET="$TMP/asset"

  printf 'fake uv archive\n' > "$STUB_ASSET"

  local arch asset version
  for arch in amd64 arm64; do
    case "$arch" in
      amd64) asset='uv-x86_64-unknown-linux-gnu.tar.gz' ;;
      arm64) asset='uv-aarch64-unknown-linux-gnu.tar.gz' ;;
    esac
    version="$(sed -n 's/^ARG UV_VERSION=//p' "$DOCKERFILE" | head -1)"

    {
      printf 'version\tfilename\tarch\tsha256\n'
      printf '%s\t%s\t%s\t%s\n' "$version" "$asset" "$arch" "$(sha256_of "$STUB_ASSET")"
    } > "$TMP/manifest"
    : > "$STUB_LOG"
    export STUB_ARCH="$arch"

    run exec_block "$DOCKERFILE" 'astral-sh/uv/releases' "$TMP/manifest"
    [ "$status" -eq 0 ]
    grep -q '^tar ' "$STUB_LOG"
    grep -q '^install ' "$STUB_LOG"
  done

  # Wrong hash: the block must abort before tar/install.
  {
    printf 'version\tfilename\tarch\tsha256\n'
    printf '%s\t%s\t%s\t%s\n' "$version" 'uv-x86_64-unknown-linux-gnu.tar.gz' amd64 "$(sha_for 71)"
  } > "$TMP/manifest"
  : > "$STUB_LOG"
  export STUB_ARCH=amd64

  run exec_block "$DOCKERFILE" 'astral-sh/uv/releases' "$TMP/manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256 mismatch"* ]]
  run grep -q '^tar ' "$STUB_LOG"
  [ "$status" -ne 0 ]
  run grep -q '^install ' "$STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "go RUN block verifies before extraction and fails when GOSUMDB is off" {
  install_stubs
  export STUB_LOG="$TMP/stubs.log" STUB_ASSET="$TMP/asset"
  printf 'fake go archive\n' > "$STUB_ASSET"

  local version asset
  version="$(sed -n 's/^ARG GO_VERSION=//p' "$DOCKERFILE" | head -1)"
  asset="go${version}.linux-amd64.tar.gz"
  {
    printf 'version\tfilename\tarch\tsha256\n'
    printf '%s\t%s\t%s\t%s\n' "$version" "$asset" amd64 "$(sha256_of "$STUB_ASSET")"
  } > "$TMP/manifest"
  : > "$STUB_LOG"
  export STUB_ARCH=amd64 STUB_GO_VERSION="$version" STUB_GOSUMDB='sum.golang.org'

  run exec_block "$DOCKERFILE" 'go.dev/dl' "$TMP/manifest"
  [ "$status" -eq 0 ]
  grep -q '^tar ' "$STUB_LOG"
  grep -q '^ln ' "$STUB_LOG"
  [[ "$output" == *'GOSUMDB=sum.golang.org'* ]]

  # The build-time guard is real: off must fail even with verified bytes.
  export STUB_GOSUMDB='off'
  run exec_block "$DOCKERFILE" 'go.dev/dl' "$TMP/manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GOSUMDB must not be off"* ]]

  # And extraction still happens only after a matching hash.
  {
    printf 'version\tfilename\tarch\tsha256\n'
    printf '%s\t%s\t%s\t%s\n' "$version" "$asset" amd64 "$(sha_for 72)"
  } > "$TMP/manifest"
  : > "$STUB_LOG"
  export STUB_GOSUMDB='sum.golang.org'
  run exec_block "$DOCKERFILE" 'go.dev/dl' "$TMP/manifest"
  [ "$status" -ne 0 ]
  run grep -q '^tar ' "$STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "bump-pinned moves Go ARG + both hashes together and never touches other pins" {
  grep -qF "go.dev/dl/?mode=json" "$BUMP_WORKFLOW"
  run grep -q 'include=all' "$BUMP_WORKFLOW"
  [ "$status" -ne 0 ]
  grep -qF 'scripts/image-assets.sh update-go config/image-assets.sha256' "$BUMP_WORKFLOW"
  grep -qF 'git add Dockerfile config/image-assets.sha256' "$BUMP_WORKFLOW"
  grep -qF 'registry.npmjs.org/playwright/latest' "$BUMP_WORKFLOW"
  grep -qF 'git commit -m "chore: bump pinned Playwright/Go"' "$BUMP_WORKFLOW"

  # One commit, one `git add`: the transaction cannot smuggle in other files.
  [ "$(grep -cE '^[[:space:]]*git add ' "$BUMP_WORKFLOW")" -eq 1 ]

  # Never auto-update the human-reviewed pins/digests.
  run grep -qE 'UV_VERSION|MARKSMAN|POWERSHELL|af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0|6c295e41755ead3667779650473515bf70ddd8096e8ad8a4af4d488026c127b9' "$BUMP_WORKFLOW"
  [ "$status" -ne 0 ]
}

@test "the real manifest entries use the versions the Dockerfiles download" {
  local uv go
  uv="$(sed -n 's/^ARG UV_VERSION=//p' "$DOCKERFILE" | head -1)"
  go="$(sed -n 's/^ARG GO_VERSION=//p' "$DOCKERFILE" | head -1)"

  grep -qF "$(printf '%s\t%s\tamd64\t' "$uv" 'uv-x86_64-unknown-linux-gnu.tar.gz')" "$MANIFEST"
  grep -qF "$(printf '%s\t%s\tarm64\t' "$uv" 'uv-aarch64-unknown-linux-gnu.tar.gz')" "$MANIFEST"
  grep -qF "$(printf '%s\t%s\tamd64\t' "$go" "go${go}.linux-amd64.tar.gz")" "$MANIFEST"
  grep -qF "$(printf '%s\t%s\tarm64\t' "$go" "go${go}.linux-arm64.tar.gz")" "$MANIFEST"
  grep -qF $'2026-02-08\tmarksman-linux-x64\tamd64\t' "$MANIFEST"
  grep -qF $'2026-02-08\tmarksman-linux-arm64\tarm64\t' "$MANIFEST"
  grep -qF $'7.6.7\tpowershell_7.6.7-1.deb_amd64.deb\tamd64\t' "$MANIFEST"
  grep -qF $'7.6.7\tpowershell_7.6.7-1.deb_arm64.deb\tarm64\t' "$MANIFEST"
}
