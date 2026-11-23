#!/usr/bin/env bats
# P2-A2: the Docker build context must exclude local test output, the local env
# template, private planning notes and the progress notepad, while every input
# the build actually consumes stays inside the context.
#
# Offline: no docker, no daemon, no network. The first tests read the real
# .dockerignore; the last one builds a temporary fixture tree that mirrors the
# repository layout and classifies it with a small, documented matcher for the
# simple patterns this repository uses.

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  DOCKERIGNORE="$REPO_ROOT/.dockerignore"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Minimal .dockerignore matcher — a documented subset, kept deliberately small:
#   * blank lines and `#` comments are skipped;
#   * `!` negation is unsupported (the file has none): the matcher returns 2 so
#     a future negation cannot be silently mis-evaluated;
#   * patterns and paths are split on `/` and matched component by component,
#     so `*.tar.gz` (like Go's filepath.Match) only covers the context root;
#   * `*` and `?` match inside ONE component;
#   * `**` matches zero or more whole components;
#   * a pattern matching a directory also excludes its whole subtree, which is
#     reproduced by re-testing every ancestor prefix of the candidate path.
# ---------------------------------------------------------------------------
_match_comps() { # $1 = pattern component index, $2 = path component index
  local i="$1" j="$2" k
  if (( i == ${#_PAT[@]} )); then
    (( j == ${#_PTH[@]} ))
    return
  fi
  if [[ ${_PAT[$i]} == '**' ]]; then
    for (( k = j; k <= ${#_PTH[@]}; k++ )); do
      _match_comps $(( i + 1 )) "$k" && return 0
    done
    return 1
  fi
  (( j < ${#_PTH[@]} )) || return 1
  # Unquoted RHS keeps glob semantics for `*` / `?` inside the component.
  [[ ${_PTH[$j]} == ${_PAT[$i]} ]] || return 1
  _match_comps $(( i + 1 )) $(( j + 1 ))
}

_pattern_matches() { # $1 = pattern, $2 = candidate path
  local IFS='/'
  local -a _PAT _PTH
  read -r -a _PAT <<< "$1"
  read -r -a _PTH <<< "$2"
  _match_comps 0 0
}

trim() { # $1 = string; strips surrounding blanks
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_ignored() { # $1 = path relative to the build context; 0 = ignored, 1 = kept
  local path="${1#./}" pattern probe
  while IFS= read -r pattern || [[ -n $pattern ]]; do
    pattern="$(trim "$pattern")"
    [[ -z $pattern ]] && continue
    [[ $pattern == '#'* ]] && continue
    [[ $pattern == '!'* ]] && return 2
    while [[ $pattern == */ ]]; do pattern="${pattern%/}"; done
    probe="$path"
    while :; do
      _pattern_matches "$pattern" "$probe" && return 0
      [[ $probe == */* ]] || break
      probe="${probe%/*}"
    done
  done < "$DOCKERIGNORE"
  return 1
}

@test "dockerignore keeps the four local-only exclusions" {
  local entry
  for entry in testResults.xml .env.example .omo PROGRESS.md; do
    if ! grep -qxF -- "$entry" "$DOCKERIGNORE"; then
      echo "missing .dockerignore exclusion: $entry" >&2
      return 1
    fi
  done
}

@test "dockerignore has no negation patterns (matcher contract)" {
  if grep -qE '^[[:space:]]*!' "$DOCKERIGNORE"; then
    echo "negation patterns are unsupported here; extend the matcher first" >&2
    return 1
  fi
}

@test "build-critical inputs stay inside the context" {
  local f
  for f in \
    windows/install.ps1 \
    windows/SHA256SUMS \
    config/image-assets.sha256 \
    scripts/image-assets.sh \
    Dockerfile \
    Dockerfile.agents \
    Dockerfile.wsl \
    .dockerignore; do
    if is_ignored "$f"; then
      echo "critical build input would be excluded: $f" >&2
      return 1
    fi
  done
}

@test "fixture: sensitive files are excluded, critical files are included" {
  local -a sensitive=(testResults.xml .env.example .omo/plan.md PROGRESS.md)
  local -a critical=(
    windows/install.ps1
    windows/SHA256SUMS
    config/image-assets.sha256
    scripts/image-assets.sh
    Dockerfile
    Dockerfile.agents
    Dockerfile.wsl
  )
  local rel

  # Materialise the fixture tree exactly as the repository lays it out.
  for rel in "${sensitive[@]}" "${critical[@]}"; do
    mkdir -p "$TMP/ctx/$(dirname "$rel")"
    : > "$TMP/ctx/$rel"
  done

  # Guard the fixture itself: every expected file must really exist.
  for rel in "${sensitive[@]}" "${critical[@]}"; do
    [[ -f "$TMP/ctx/$rel" ]] || { echo "fixture missing: $rel" >&2; return 1; }
  done

  for rel in "${sensitive[@]}"; do
    if ! is_ignored "$rel"; then
      echo "sensitive file would enter the build context: $rel" >&2
      return 1
    fi
  done

  for rel in "${critical[@]}"; do
    if is_ignored "$rel"; then
      echo "critical file would leave the build context: $rel" >&2
      return 1
    fi
  done
}
