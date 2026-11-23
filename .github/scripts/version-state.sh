#!/usr/bin/env bash
# version-state — build-state gate and inventory merge (P1-2).
#
# The CI build state is one v2 manifest with four parts:
#   floating  upstream packages that are followed (track=true)
#   fixed     pinned inventory/metadata (base/core digests, tool releases);
#             NEVER compared with upstream
#   tools     versions actually installed in the image, per arch
#   packages  dpkg versions actually installed, per arch
#
# Commands:
#   --emit changed --manifest FILE [--upstream FILE | --fixture-dir DIR] --now ISO8601
#       Decide whether a scheduled build is needed. Compares only tracked
#       floating keys against `tools.<package>` for amd64+arm64. Always exits 0
#       on a verdict (fail-open reasons included); exits 1 on a damaged/invalid
#       manifest or an invalid/future last_built; exits 2 on usage errors.
#
#       Output (line protocol, no other stdout):
#         changed=true|false
#         reason=query-error|missing-key|upstream-change|stale|none
#         changed-key=<floating key>       (one per changed entry, sorted)
#         changed-tool=<package>           (paired with changed-key)
#
#       Priority: query-error > missing-key > upstream-change > stale.
#       A stale (28 days since last_built) build, a failed/empty query, a
#       missing tools key/arch and a missing/null last_built all fail open
#       (changed=true) so the next build repairs the state.
#
#   --emit manifest [--manifest FILE]
#       Print the normalized, stable-sorted v2 manifest on stdout. A legacy
#       flat manifest (the old versions.json) is migrated to v2 here and
#       nowhere else. Defaults to versions.json at the repo root.
#
#   merge --build-dir DIR --out FILE [--manifest FILE]
#       Merge every per-arch inventory (*.json with a top-level `arch`) from
#       DIR into a v2 manifest. `manifest.json` is the base manifest, never an
#       inventory; JSON files without `arch` are not inventories. Writes
#       atomically (temp file in the output directory + mv). A duplicate arch
#       writes exactly `DUPLICATE_ARCH=<arch>` to stderr, exits 2, and never
#       creates or overwrites --out.
#
# Offline: --fixture-dir DIR reads DIR/upstream.json and never touches the
# network. --upstream FILE overrides it. Without either, npm/PyPI are queried.
# The upstream sample is a flat map of "<ecosystem>:<package>" -> version plus
# optional `errors`/`missing` arrays that model a failed query or an absent
# upstream entry.
set -euo pipefail
export LC_ALL=C

PROG="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROG SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT
STALE_SECONDS=$((28 * 24 * 60 * 60))
readonly STALE_SECONDS
readonly MINIMAL_MANIFEST='{"schemaVersion":2,"floating":{},"fixed":{},"tools":{},"packages":{"dpkg":{}},"last_built":null}'

WORK_DIR=""
OUT_TMP=""

cleanup() {
  if [ -n "$OUT_TMP" ]; then rm -f -- "$OUT_TMP"; fi
  if [ -n "$WORK_DIR" ]; then rm -rf -- "$WORK_DIR"; fi
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
usage: version-state.sh --emit changed --manifest FILE [--upstream FILE | --fixture-dir DIR] --now ISO8601
       version-state.sh --emit manifest [--manifest FILE]
       version-state.sh merge --build-dir DIR --out FILE [--manifest FILE]
EOF
  exit 2
}

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

is_iso_utc() {
  local value="$1" roundtrip
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  roundtrip="$(date -u -d "$value" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 1
  [ "$roundtrip" = "$value" ]
}

iso_epoch() {
  date -u -d "$1" +%s
}

# Print the canonical v2 form of a v1-flat or v2 manifest. Returns 1 (with no
# stdout) for damaged JSON or a schema that is neither.
normalize_manifest() {
  local file="$1"
  if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    return 1
  fi
  if jq -e 'has("schemaVersion")' "$file" >/dev/null 2>&1; then
    if ! jq -e '
        (.schemaVersion == 2)
        and ((.floating | type) == "object")
        and (((.fixed // {}) | type) == "object")
        and (((.tools // {}) | type) == "object")
        and (((.packages // {}) | type) == "object")
        and ((has("last_built") | not) or (.last_built == null) or ((.last_built | type) == "string"))
      ' "$file" >/dev/null 2>&1; then
      return 1
    fi
    jq -S '{
      schemaVersion: 2,
      floating: .floating,
      fixed: (.fixed // {}),
      tools: (.tools // {}),
      packages: ((.packages // {}) + (if ((.packages // {}) | has("dpkg")) then {} else {dpkg: {}} end)),
      last_built: (if has("last_built") then .last_built else null end)
    }' "$file"
  else
    # Legacy flat manifest: every non-_comment key is a tracked package.
    if ! jq -e '
        ([to_entries[] | select(.key != "_comment") | (.value | type == "string")] | all)
      ' "$file" >/dev/null 2>&1; then
      return 1
    fi
    jq -S '{
      schemaVersion: 2,
      floating: ([to_entries[] | select(.key != "_comment") | {
        key: (if .key == "aider-chat" then "pypi:aider-chat" else ("npm:" + .key) end),
        value: {
          ecosystem: (if .key == "aider-chat" then "pypi" else "npm" end),
          package: .key,
          track: true
        }
      }] | from_entries),
      fixed: {},
      tools: {},
      packages: {dpkg: {}},
      last_built: null
    }' "$file"
  fi
}

# Look up one tracked key in the offline upstream sample.
# Prints "<status>\t<version>" where status is ok|error|missing.
fixture_lookup() {
  local file="$1" upstream_ok="$2" key="$3" value
  if [ "$upstream_ok" -ne 1 ]; then
    printf 'error\t\n'
    return 0
  fi
  if jq -e --arg k "$key" '((.errors // []) | index($k)) != null' "$file" >/dev/null 2>&1; then
    printf 'error\t\n'
    return 0
  fi
  if jq -e --arg k "$key" '((.missing // []) | index($k)) != null' "$file" >/dev/null 2>&1; then
    printf 'missing\t\n'
    return 0
  fi
  if ! jq -e --arg k "$key" 'has($k)' "$file" >/dev/null 2>&1; then
    printf 'missing\t\n'
    return 0
  fi
  if ! jq -e --arg k "$key" '.[$k] | (type == "string") and (. != "")' "$file" >/dev/null 2>&1; then
    printf 'error\t\n'
    return 0
  fi
  value="$(jq -r --arg k "$key" '.[$k]' "$file")"
  printf 'ok\t%s\n' "$value"
}

query_npm() {
  local package="$1" value
  value="$(npm view "$package" version 2>/dev/null)" || return 1
  value="$(printf '%s' "$value" | tr -d '[:space:]')"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

query_pypi() {
  local package="$1" body value
  body="$(curl -fsS --max-time 20 "https://pypi.org/pypi/${package}/json" 2>/dev/null)" || return 1
  value="$(printf '%s' "$body" | jq -r 'if ((.info.version | type) == "string") then .info.version else "" end' 2>/dev/null)" || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

cmd_changed() {
  local manifest="$1" now="$2" upstream="$3"
  local norm queries result lb lb_missing now_epoch lb_epoch stale upstream_ok
  local key ecosystem package status version

  WORK_DIR="$(mktemp -d)"
  norm="$WORK_DIR/manifest.norm.json"
  if ! normalize_manifest "$manifest" >"$norm"; then
    die "invalid manifest: $manifest"
  fi

  now_epoch="$(iso_epoch "$now")"
  lb="$(jq -r 'if (has("last_built") and (.last_built != null)) then .last_built else "" end' "$norm")"
  lb_missing=false
  stale=false
  if [ -z "$lb" ]; then
    lb_missing=true
  else
    is_iso_utc "$lb" || die "invalid last_built: $lb"
    lb_epoch="$(iso_epoch "$lb")"
    if [ "$lb_epoch" -gt "$now_epoch" ]; then
      die "last_built is in the future: $lb"
    fi
    if [ "$now_epoch" -ge $((lb_epoch + STALE_SECONDS)) ]; then
      stale=true
    fi
  fi

  upstream_ok=0
  if [ -n "$upstream" ]; then
    if [ -f "$upstream" ] && jq -e '
        (type == "object")
        and (((.errors // []) | type) == "array")
        and (((.missing // []) | type) == "array")
      ' "$upstream" >/dev/null 2>&1; then
      upstream_ok=1
    fi
  fi

  queries="$WORK_DIR/queries.jsonl"
  : >"$queries"
  while IFS=$'\t' read -r key ecosystem package; do
    [ -n "$key" ] || continue
    status=""
    version=""
    if [ -n "$upstream" ]; then
      IFS=$'\t' read -r status version < <(fixture_lookup "$upstream" "$upstream_ok" "$key") || true
    else
      status="error"
      case "$ecosystem" in
        npm)
          if version="$(query_npm "$package")"; then status="ok"; fi
          ;;
        pypi)
          if version="$(query_pypi "$package")"; then status="ok"; fi
          ;;
        *)
          status="error"
          version=""
          ;;
      esac
    fi
    jq -nc --arg key "$key" --arg package "$package" --arg status "$status" --arg version "$version" \
      '{key:$key,package:$package,status:$status,version:$version}' >>"$queries"
  done < <(jq -r '.floating | to_entries[]
                   | select((.value.track // false) == true)
                   | [.key, (.value.ecosystem // ""), (.value.package // "")] | @tsv' "$norm")

  result="$(jq -rn \
    --slurpfile manifest "$norm" \
    --slurpfile queries "$queries" \
    --argjson stale "$stale" \
    --argjson lb_missing "$lb_missing" '
      ($manifest[0]) as $m
      | [$queries[] | . as $q
          | ($m.tools[$q.package] // null) as $tool
          | if $q.status == "error" then
              {key: $q.key, package: $q.package, cls: "query-error"}
            elif $q.status == "missing" then
              {key: $q.key, package: $q.package, cls: "missing-key"}
            elif (($tool | type) == "object")
                 and (($tool.amd64 | type) == "string") and ($tool.amd64 != "")
                 and (($tool.arm64 | type) == "string") and ($tool.arm64 != "") then
              if ($q.version != $tool.amd64) or ($q.version != $tool.arm64) then
                {key: $q.key, package: $q.package, cls: "upstream-change"}
              else
                {key: $q.key, package: $q.package, cls: "ok"}
              end
            else
              {key: $q.key, package: $q.package, cls: "missing-key"}
            end
        ] as $rows
      | ($rows | map(select(.cls == "query-error")) | length) as $nerr
      | ($rows | map(select(.cls == "missing-key")) | length) as $nmiss
      | ($rows | map(select(.cls == "upstream-change")) | length) as $nchg
      | (if $nerr > 0 then "query-error"
         elif ($nmiss > 0 or $lb_missing) then "missing-key"
         elif $nchg > 0 then "upstream-change"
         elif $stale then "stale"
         else "none" end) as $reason
      | ($rows
         | map(select(.cls == "query-error" or .cls == "missing-key" or .cls == "upstream-change"))
         | sort_by(.key)) as $changed
      | "changed=" + (if $reason == "none" then "false" else "true" end),
        "reason=" + $reason,
        ($changed[] | ("changed-key=" + .key), ("changed-tool=" + .package))
    ')"
  printf '%s\n' "$result"
}

cmd_manifest() {
  local manifest="$1" output
  output="$(normalize_manifest "$manifest")" || die "invalid manifest: $manifest"
  printf '%s\n' "$output"
}

cmd_merge() {
  local build_dir="" out="" base_arg=""
  local base_src base_norm inv_json outdir f base arch built_at pkg ver
  local -a files=()
  local -a inv_files=()
  local -A seen_arch=()
  local -A pkg_version=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --build-dir)
        [ "$#" -ge 2 ] || usage
        build_dir="$2"
        shift 2
        ;;
      --out)
        [ "$#" -ge 2 ] || usage
        out="$2"
        shift 2
        ;;
      --manifest)
        [ "$#" -ge 2 ] || usage
        base_arg="$2"
        shift 2
        ;;
      *) usage ;;
    esac
  done
  if [ -z "$build_dir" ]; then usage; fi
  if [ -z "$out" ]; then usage; fi
  if [ ! -d "$build_dir" ]; then die "build dir not found: $build_dir"; fi

  WORK_DIR="$(mktemp -d)"

  base_src=""
  if [ -n "$base_arg" ]; then
    base_src="$base_arg"
  elif [ -f "$build_dir/manifest.json" ]; then
    base_src="$build_dir/manifest.json"
  fi
  base_norm="$WORK_DIR/base.json"
  if [ -n "$base_src" ]; then
    if ! normalize_manifest "$base_src" >"$base_norm"; then
      die "invalid base manifest: $base_src"
    fi
  else
    printf '%s\n' "$MINIMAL_MANIFEST" >"$base_norm"
  fi

  shopt -s nullglob
  files=("$build_dir"/*.json)
  shopt -u nullglob
  for f in "${files[@]}"; do
    base="${f##*/}"
    if [ "$base" = "manifest.json" ]; then
      continue
    fi
    if ! jq -e 'type == "object" and has("arch")' "$f" >/dev/null 2>&1; then
      continue
    fi
    if ! jq -e '
        (.schemaVersion == 1)
        and ((.arch | type) == "string")
        and ((.variant | type) == "string")
        and ((.built_at | type) == "string")
        and ((.tools | type) == "object")
        and ([.tools[] | type == "string"] | all)
        and ((.packages | type) == "object")
        and (((.packages.dpkg // {}) | type) == "object")
        and ([.packages.dpkg[]? | type == "string"] | all)
      ' "$f" >/dev/null 2>&1; then
      die "invalid inventory: $f"
    fi
    arch="$(jq -r '.arch' "$f")"
    case "$arch" in
      amd64|arm64) ;;
      *) die "invalid arch in $f: $arch" ;;
    esac
    if [ -n "${seen_arch[$arch]:-}" ]; then
      printf 'DUPLICATE_ARCH=%s\n' "$arch" >&2
      exit 2
    fi
    seen_arch[$arch]=1
    built_at="$(jq -r '.built_at' "$f")"
    is_iso_utc "$built_at" || die "invalid built_at in $f: $built_at"
    while IFS=$'\t' read -r pkg ver; do
      [ -n "$pkg" ] || continue
      if [ -n "${pkg_version[$arch/$pkg]:-}" ] && [ "${pkg_version[$arch/$pkg]}" != "$ver" ]; then
        die "package version conflict for $pkg on $arch"
      fi
      pkg_version[$arch/$pkg]="$ver"
    done < <(jq -r '.packages.dpkg // {} | to_entries[] | [.key, (.value | tostring)] | @tsv' "$f")
    inv_files+=("$f")
  done

  if [ "${#inv_files[@]}" -eq 0 ]; then
    die "no inventory files found in $build_dir"
  fi

  inv_json="$WORK_DIR/inventories.json"
  jq -s '.' "${inv_files[@]}" >"$inv_json"

  outdir="$(dirname "$out")"
  if [ ! -d "$outdir" ]; then
    die "output directory not found: $outdir"
  fi
  OUT_TMP="$(mktemp "$outdir/.version-state.XXXXXX")"
  jq -S -n --slurpfile base "$base_norm" --slurpfile inv "$inv_json" '
    ($base[0]) as $b
    | ($inv[0]) as $iv
    | {
        schemaVersion: 2,
        floating: $b.floating,
        fixed: $b.fixed,
        tools: (reduce $iv[] as $i ({};
          reduce ($i.tools | to_entries[]) as $t (.;
            .[$t.key] = ((.[$t.key] // {}) + {($i.arch): $t.value})))),
        packages: {
          dpkg: (reduce $iv[] as $i ({};
            reduce ($i.packages.dpkg // {} | to_entries[]) as $p (.;
              (.[$i.arch] //= {}) | .[$i.arch][$p.key] = $p.value)))
        },
        last_built: ($iv | map(.built_at) | max)
      }
  ' >"$OUT_TMP"
  mv -f -- "$OUT_TMP" "$out"
  OUT_TMP=""
}

cmd_query() {
  local emit="" manifest="" upstream="" fixture="" now=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --emit)
        [ "$#" -ge 2 ] || usage
        emit="$2"
        shift 2
        ;;
      --manifest)
        [ "$#" -ge 2 ] || usage
        manifest="$2"
        shift 2
        ;;
      --upstream)
        [ "$#" -ge 2 ] || usage
        upstream="$2"
        shift 2
        ;;
      --fixture-dir)
        [ "$#" -ge 2 ] || usage
        fixture="$2"
        shift 2
        ;;
      --now)
        [ "$#" -ge 2 ] || usage
        now="$2"
        shift 2
        ;;
      *) usage ;;
    esac
  done

  case "$emit" in
    changed|manifest) ;;
    "") usage ;;
    *) usage ;;
  esac

  if [ -z "$manifest" ] && [ -n "$fixture" ]; then
    manifest="$fixture/manifest.json"
  fi
  if [ -z "$manifest" ]; then
    if [ "$emit" = "manifest" ]; then
      manifest="$REPO_ROOT/versions.json"
    else
      usage
    fi
  fi
  if [ ! -f "$manifest" ]; then
    die "manifest not found: $manifest"
  fi

  if [ "$emit" = "manifest" ]; then
    cmd_manifest "$manifest"
    return 0
  fi

  if [ -z "$now" ]; then
    usage
  fi
  is_iso_utc "$now" || usage
  if [ -z "$upstream" ] && [ -n "$fixture" ]; then
    upstream="$fixture/upstream.json"
  fi
  cmd_changed "$manifest" "$now" "$upstream"
}

if [ "$#" -eq 0 ]; then
  usage
fi
case "$1" in
  merge)
    shift
    cmd_merge "$@"
    ;;
  --emit|--manifest|--upstream|--fixture-dir|--now)
    cmd_query "$@"
    ;;
  *)
    usage
    ;;
esac
