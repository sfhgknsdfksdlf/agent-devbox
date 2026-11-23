#!/usr/bin/env bash
# version-inventory — record what this image ACTUALLY installed (P1-2).
#
# Runs INSIDE a built image (it is COPYed to /usr/local/bin by the Dockerfile L14
# `COPY scripts/`), never against the network. build/export run it per arch and
# `publish` merges the per-arch inventories into the v2 build-state manifest:
#   tools    the exact versions installed in the image, per arch
#   packages the exact dpkg versions installed in the image, per arch
#
# Output (one JSON object; keys sorted, tools/dpkg sorted by version-inventory):
#   {"schemaVersion":1,"arch":"amd64","variant":"agents",
#    "built_at":"2026-11-23T00:00:00Z","tools":{...},
#    "packages":{"dpkg":{...}}}
#
# Sources (no upstream query, no "unknown" placeholders):
#   npm globals     `npm ls -g --depth=0 --json` (exact names, scoped included)
#   aider-chat      `aider --version` (the floating key is aider-chat, never aider)
#   go toolchain    `go env GOVERSION` (fallback `go version`) + gopls/dlv/wails3
#   uv toolchain    `uv --version` + `uvx --version`
#   oh-my-openagent installed by `bunx ...@latest install` (not an npm global);
#                   the exact resolved meta package is left in bun's install
#                   cache, which is the only offline source for a plugin that
#                   has no CLI --version
#   dpkg            `dpkg-query -W -f='${Package}\t${Version}\n'`, verbatim
#
# A present command whose output cannot be parsed, a missing cache for a
# package that must be recorded, or any collection failure is fatal (exit 1)
# and produces NO output. A bad/absent --arch/--variant is a usage error
# (exit 2). With --out the file is written atomically (temp + mv).
set -euo pipefail
export LC_ALL=C

PROG="${0##*/}"
ARCH=""
VARIANT=""
OUT=""
WORK=""
OUT_TMP=""

cleanup() {
  if [ -n "$OUT_TMP" ]; then rm -f -- "$OUT_TMP"; fi
  if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
usage: version-inventory.sh --arch amd64|arm64 --variant agents|core|wsl [--out FILE]
EOF
  exit 2
}

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch)
      [ "$#" -ge 2 ] || usage
      ARCH="$2"
      shift 2
      ;;
    --variant)
      [ "$#" -ge 2 ] || usage
      VARIANT="$2"
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || usage
      OUT="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$ARCH" in
  amd64|arm64) ;;
  *) usage ;;
esac
case "$VARIANT" in
  agents|core|wsl) ;;
  *) usage ;;
esac

WORK="$(mktemp -d)"
TOOLS_TSV="$WORK/tools.tsv"
: >"$TOOLS_TSV"

# First X.Y.Z (optional -pre/+build suffix) on the first matching line. A
# leading `v`/`go` is not part of the group, so "go1.27.2" -> "1.27.2" and
# "v3.0.0-beta.30" -> "3.0.0-beta.30".
extract_version() {
  sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\([-+][0-9A-Za-z.-]*\)\{0,1\}\).*/\1/p' | head -n 1
}

# record_tool <key> <cmd> [args...]
# Missing command = not installed here (skip). Present but failing/unparseable =
# fatal, because a declared tool silently missing its version would poison the
# state used by the scheduled diff-gate.
record_tool() {
  local key="$1"
  local cmd="$2"
  shift 2
  local out version errfile

  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  errfile="$WORK/tool-$key.err"
  if ! out="$("$cmd" "$@" 2>"$errfile")"; then
    die "declared tool '$cmd' is installed but its version command failed"
  fi
  version="$(printf '%s\n' "$out" | extract_version)"
  # `wails3 version` prints to stderr (exit 0), so stderr is a legitimate
  # fallback only when stdout carried no version token.
  if [ -z "$version" ]; then
    version="$(extract_version <"$errfile")"
  fi
  if [ -z "$version" ]; then
    die "cannot parse the version output of '$cmd'"
  fi
  printf '%s\t%s\n' "$key" "$version" >>"$TOOLS_TSV"
}

# --- npm global packages -----------------------------------------------------
npm_json="$WORK/npm.json"
# `npm ls` exits non-zero when the global tree has extraneous entries; the JSON
# is still authoritative, so only a parse failure is fatal.
if ! npm ls -g --depth=0 --json >"$npm_json" 2>"$WORK/npm.err"; then
  :
fi
if ! jq -e '
    (.dependencies // {}) as $d
    | (($d | type) == "object")
      and ([$d | to_entries[]
            | ((.value.version | type) == "string") and (.value.version != "")
           ] | all)
  ' "$npm_json" >/dev/null 2>&1; then
  die "cannot parse npm global package list"
fi
jq -r '(.dependencies // {}) | to_entries[] | [.key, .value.version] | @tsv' \
  "$npm_json" >>"$TOOLS_TSV"

# --- aider (uv tool shim) ----------------------------------------------------
record_tool aider-chat aider --version

# --- Go toolchain actuals ----------------------------------------------------
if command -v go >/dev/null 2>&1; then
  go_out=""
  if ! go_out="$(go env GOVERSION 2>/dev/null)" || [ -z "$go_out" ]; then
    if ! go_out="$(go version 2>/dev/null)"; then
      die "declared tool 'go' is installed but its version command failed"
    fi
  fi
  go_version="$(printf '%s\n' "$go_out" | extract_version)"
  [ -n "$go_version" ] || die "cannot parse the version output of 'go'"
  printf 'go\t%s\n' "$go_version" >>"$TOOLS_TSV"
fi
record_tool gopls gopls version
record_tool dlv dlv version
record_tool wails3 wails3 version
record_tool uv uv --version
record_tool uvx uvx --version

# --- oh-my-openagent (bunx @latest plugin installer) -------------------------
# Dockerfile L12 runs `bunx oh-my-openagent@latest install`; bun keeps the exact
# resolved meta package under its install cache. The plugin itself has no
# `--version`, so this is the installed version the floating gate must compare.
OMO_CACHE="${AGENT_DEVBOX_OMO_CACHE:-/opt/agent-seed/.bun/install/cache}"
[ -d "$OMO_CACHE" ] || die "oh-my-openagent cache not found: $OMO_CACHE"
mapfile -t omo_manifests < <(
  find "$OMO_CACHE" -maxdepth 2 -type f -path '*/oh-my-openagent@*/package.json' | sort
)
[ "${#omo_manifests[@]}" -gt 0 ] || die "no oh-my-openagent package in $OMO_CACHE"
omo_versions=()
for manifest in "${omo_manifests[@]}"; do
  omo_version="$(jq -r 'select(.name == "oh-my-openagent") | .version' "$manifest")"
  [ -n "$omo_version" ] || die "cannot parse oh-my-openagent manifest: $manifest"
  omo_versions+=("$omo_version")
done
mapfile -t omo_unique < <(printf '%s\n' "${omo_versions[@]}" | sort -u)
if [ "${#omo_unique[@]}" -ne 1 ]; then
  die "ambiguous oh-my-openagent cache versions: ${omo_unique[*]}"
fi
printf 'oh-my-openagent\t%s\n' "${omo_unique[0]}" >>"$TOOLS_TSV"

# --- dpkg packages -----------------------------------------------------------
if ! dpkg-query -W -f='${Package}\t${Version}\n' >"$WORK/dpkg.raw" 2>"$WORK/dpkg.err"; then
  die "cannot list dpkg packages"
fi
if ! awk -F'\t' 'NF != 2 || $1 == "" { bad = 1 } END { exit bad ? 1 : 0 }' "$WORK/dpkg.raw"; then
  die "unexpected dpkg-query output"
fi
sort "$WORK/dpkg.raw" >"$WORK/dpkg.tsv"

# --- assemble ----------------------------------------------------------------
if ! awk -F'\t' 'NF != 2 || $1 == "" || $2 == "" { bad = 1 } END { exit bad ? 1 : 0 }' "$TOOLS_TSV"; then
  die "unexpected tool inventory rows"
fi

jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries' \
  "$TOOLS_TSV" >"$WORK/tools.json"
jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries' \
  "$WORK/dpkg.tsv" >"$WORK/dpkg.json"

built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -S -n \
  --arg arch "$ARCH" \
  --arg variant "$VARIANT" \
  --arg built_at "$built_at" \
  --slurpfile tools "$WORK/tools.json" \
  --slurpfile dpkg "$WORK/dpkg.json" \
  '{schemaVersion: 1, arch: $arch, variant: $variant, built_at: $built_at,
    tools: $tools[0], packages: {dpkg: $dpkg[0]}}' >"$WORK/inventory.json"

if [ -n "$OUT" ]; then
  outdir="$(dirname "$OUT")"
  [ -d "$outdir" ] || die "output directory not found: $outdir"
  OUT_TMP="$(mktemp "$outdir/.version-inventory.XXXXXX")"
  cat "$WORK/inventory.json" >"$OUT_TMP"
  mv -f -- "$OUT_TMP" "$OUT"
  OUT_TMP=""
else
  cat "$WORK/inventory.json"
fi
