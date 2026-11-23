#!/usr/bin/env bash
# Release identity + ordering for .github/workflows/build.yml.
#
# `plan` prints the GHCR candidate tag, the Release tag, the alias flags and the
# channel for one run. `is-newer` / `newest` implement the anti-regression guard
# (an older run/attempt must never prune or write state).
#
# Tags:
#   schedule/dispatch  tag=<ts>-<run>.<attempt>        release=build-<ts>-<run>.<attempt>
#   push to main       tag=<ts>-<run>.<attempt>        release=beta-<ts>-<run>.<attempt>
#   push to non-main   tag=beta-<ts>-<run>.<attempt>   release=beta-<ts>-<run>.<attempt>
# Legacy (pre-P0-2) date-only tags have no suffix; for ordering they are older
# than a suffixed tag in the same minute.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: release-tags.sh plan --event <schedule|workflow_dispatch|push> --ref <ref>
                            --run-id <id> --attempt <n> --ts <YYYYMMDD.HHMM>
       release-tags.sh is-newer --candidate <tag> [--latest <tag>] [--allow-equal]
       release-tags.sh newest   (tags on stdin, newest on stdout)
EOF
  exit 2
}

die() { echo "ERROR: $*" >&2; exit 2; }

# parse_tag <tag> -> "ts|run_id|attempt|has_suffix"
parse_tag() {
  local t="$1" body ts suffix rid att
  case "$t" in
    build-*) ;;
    beta-*) ;;
    *) return 1 ;;
  esac
  body="${t#*-}"
  ts="${body%%-*}"
  suffix=""
  if [ "$ts" != "$body" ]; then suffix="${body#*-}"; fi
  if ! [[ "$ts" =~ ^[0-9]{8}\.[0-9]{4}$ ]]; then return 1; fi
  rid=""
  att=""
  if [ -n "$suffix" ]; then
    if ! [[ "$suffix" =~ ^[0-9]+\.[0-9]+$ ]]; then return 1; fi
    rid="${suffix%%.*}"
    att="${suffix##*.}"
    printf '%s|%s|%s|1\n' "$ts" "$rid" "$att"
  else
    printf '%s|%s|%s|0\n' "$ts" "$rid" "$att"
  fi
}

# is_newer <candidate> <latest> <allow_equal:0|1>
# exit 0 = candidate is newer (or equal when allowed); 1 = not newer; 2 = invalid.
is_newer() {
  local c="$1" l="$2" allow="$3" cts crid catt chas lts lrid latt lhas
  IFS='|' read -r cts crid catt chas <<<"$(parse_tag "$c" || true)"
  IFS='|' read -r lts lrid latt lhas <<<"$(parse_tag "$l" || true)"
  [ -n "$cts" ] || return 2
  [ -n "$lts" ] || return 2
  if [[ "$cts" > "$lts" ]]; then return 0; fi
  if [[ "$cts" < "$lts" ]]; then return 1; fi
  if [ "$chas" -eq 0 ] && [ "$lhas" -eq 0 ]; then
    if [ "$allow" = "1" ]; then return 0; fi
    return 1
  fi
  if [ "$chas" -eq 1 ] && [ "$lhas" -eq 0 ]; then return 0; fi
  if [ "$chas" -eq 0 ] && [ "$lhas" -eq 1 ]; then return 1; fi
  if [ "$crid" -gt "$lrid" ]; then return 0; fi
  if [ "$crid" -lt "$lrid" ]; then return 1; fi
  if [ "$catt" -gt "$latt" ]; then return 0; fi
  if [ "$allow" = "1" ] && [ "$catt" -eq "$latt" ]; then return 0; fi
  return 1
}

cmd_plan() {
  local event="" ref="" run_id="" attempt="" ts=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --event) event="$2"; shift 2 ;;
      --ref) ref="$2"; shift 2 ;;
      --run-id) run_id="$2"; shift 2 ;;
      --attempt) attempt="$2"; shift 2 ;;
      --ts) ts="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$event" ] || die "--event is required"
  [ -n "$ref" ] || die "--ref is required"
  [ -n "$ts" ] || die "--ts is required"
  [[ "$ts" =~ ^[0-9]{8}\.[0-9]{4}$ ]] || die "invalid timestamp: $ts"
  [[ "$run_id" =~ ^[1-9][0-9]*$ ]] || die "invalid run id: '${run_id}'"
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || die "invalid run attempt: '${attempt}'"

  local tag release_tag promote beta_alias channel
  case "$event" in
    schedule|workflow_dispatch)
      tag="${ts}-${run_id}.${attempt}"
      release_tag="build-${ts}-${run_id}.${attempt}"
      promote="true"
      beta_alias="false"
      channel="stable"
      ;;
    push)
      if [ "$ref" = "refs/heads/main" ]; then
        tag="${ts}-${run_id}.${attempt}"
        release_tag="beta-${ts}-${run_id}.${attempt}"
      else
        tag="beta-${ts}-${run_id}.${attempt}"
        release_tag="beta-${ts}-${run_id}.${attempt}"
      fi
      promote="false"
      beta_alias="true"
      channel="beta"
      ;;
    *) die "unsupported event: $event" ;;
  esac

  printf 'tag=%s\n' "$tag"
  printf 'release_tag=%s\n' "$release_tag"
  printf 'promote=%s\n' "$promote"
  printf 'beta_alias=%s\n' "$beta_alias"
  printf 'channel=%s\n' "$channel"
}

cmd_is_newer() {
  local candidate="" latest="" allow=0 rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --candidate) candidate="$2"; shift 2 ;;
      --latest) latest="$2"; shift 2 ;;
      --allow-equal) allow=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$candidate" ] || die "--candidate is required"
  if [ -z "$latest" ]; then return 0; fi
  set +e
  is_newer "$candidate" "$latest" "$allow"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then die "unparseable candidate/latest tag: '$candidate' / '$latest'"; fi
  return "$rc"
}

cmd_newest() {
  local best="" line rc
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -z "$best" ]; then best="$line"; continue; fi
    set +e
    is_newer "$line" "$best" 0
    rc=$?
    set -e
    if [ "$rc" -eq 2 ]; then die "unparseable tag: $line"; fi
    if [ "$rc" -eq 0 ]; then best="$line"; fi
  done
  printf '%s\n' "$best"
}

[ "$#" -gt 0 ] || usage
cmd="$1"
shift
case "$cmd" in
  plan) cmd_plan "$@" ;;
  is-newer) cmd_is_newer "$@" ;;
  newest) cmd_newest ;;
  *) usage ;;
esac
