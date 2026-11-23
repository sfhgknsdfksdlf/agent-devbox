#!/usr/bin/env bats
# P0-6b: dependency + lint policy enforcement (offline, structural).
#
# These tests read the workflow YAML itself (they do not just restate constants),
# so reverting a pin, dropping an image digest, re-adding `|| true`, deleting a
# Dockerfile from the hadolint loop, or removing Dependabot github-actions
# coverage makes them fail.
#
# Policies enforced (see .omo/plans/p0-p1-p2-fixes.md D2 and "P0-6b"):
#   - every external `uses:` is a full 40-hex commit SHA with a trailing
#     version comment (`# vN`); no `@vN` tags, branch names or short SHAs
#   - the lint container images are pinned by sha256 digest (never `:latest`)
#   - hadolint lints Dockerfile, Dockerfile.agents and Dockerfile.wsl with no
#     `|| true`, and shellcheck no longer comes from apt
#   - .github/dependabot.yml keeps its github-actions (and docker) entries

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  WF_DIR="$REPO_ROOT/.github/workflows"
  BUILD="$WF_DIR/build.yml"
}

# Print "<file>\t<full uses line>" for every `uses:` in every workflow file.
all_uses_lines() {
  local f line
  for f in "$WF_DIR"/*.yml; do
    while IFS= read -r line; do
      printf '%s\t%s\n' "${f##*/}" "$line"
    done < <(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$f" || true)
  done
}

# Extract one job's block: from "  <job>:" to the next 2-space job key.
job_block() {
  awk -v job="$1" '
    $0 == "  " job ":" { injob = 1; print; next }
    injob && /^  [A-Za-z0-9_-]+:$/ { exit }
    injob { print }
  ' "$BUILD"
}

@test "every external uses is a full 40-hex commit with a trailing version comment" {
  local file line ref rest bad=0 count=0
  while IFS=$'\t' read -r file line; do
    count=$((count + 1))
    ref="$(printf '%s\n' "$line" \
      | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//; s/[[:space:]].*$//')"

    # Local actions (./path) and docker:// refs are not external repos.
    case "$ref" in
      ./*|docker://*) continue ;;
    esac

    # Must be exactly owner/repo@<40 lowercase hex>. Rejects @v7, branches,
    # short SHAs and anything else.
    if ! printf '%s' "$ref" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$'; then
      echo "NOT PINNED TO A FULL SHA: $file: $ref"
      bad=1
      continue
    fi

    # Trailing version comment, e.g. `# v7`, must follow the ref on the line.
    rest="${line#*"$ref"}"
    if ! printf '%s' "$rest" | grep -qE '#[[:space:]]*[^[:space:]]'; then
      echo "MISSING VERSION COMMENT: $file: $ref"
      bad=1
    fi
  done < <(all_uses_lines)

  [ "$count" -ge 26 ]
  [ "$bad" -eq 0 ]
}

@test "lint container images are pinned by sha256 digest with no :latest" {
  # The exact verified pins required by the card.
  grep -qF 'koalaman/shellcheck:v0.9.0@sha256:f35e8987b02760d4e76fc99a68ad5c42cc10bb32f3dd2143a3cf92f1e5446a45' "$BUILD"
  grep -qF 'rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667' "$BUILD"
  grep -qF 'hadolint/hadolint:v2.12.0@sha256:30a8fd2e785ab6176eed53f74769e04f125afb2f74a6c52aef7d463583b6d45e' "$BUILD"

  # None of the linters may float on :latest.
  run grep -qE '(koalaman/shellcheck|rhysd/actionlint|hadolint/hadolint):latest' "$BUILD"
  [ "$status" -ne 0 ]

  # Every occurrence of a linter image must carry an @sha256: digest.
  local line
  while IFS= read -r line; do
    if ! printf '%s' "$line" | grep -q '@sha256:'; then
      echo "IMAGE WITHOUT DIGEST: $line"
      return 1
    fi
  done < <(grep -E '(koalaman/shellcheck|rhysd/actionlint|hadolint/hadolint)' "$BUILD")
}

@test "lint job runs shellcheck over the pinned file set (not from apt)" {
  local block
  block="$(job_block lint)"
  [ -n "$block" ]

  printf '%s' "$block" | grep -qF 'scripts/*.sh tests/run.sh .github/scripts/*.sh'
  printf '%s' "$block" | grep -qF -- '-s sh config/profile.d/zz-agent-devbox-session-mount.sh'
  # actionlint must keep -color.
  printf '%s' "$block" | grep -q -- '-color'

  # shellcheck must no longer be installed from apt in the lint job.
  run bash -c 'printf "%s" "$1" | grep -E "apt-get install.*shellcheck"' _ "$block"
  [ "$status" -ne 0 ]
}

@test "hadolint checks all three Dockerfiles with no '|| true'" {
  local block
  block="$(job_block lint)"
  [ -n "$block" ]

  printf '%s' "$block" | grep -q 'hadolint/hadolint'
  printf '%s' "$block" | grep -qF 'Dockerfile.agents'
  printf '%s' "$block" | grep -qF 'Dockerfile.wsl'
  # The bare Dockerfile token must be present too (not only .agents/.wsl).
  printf '%s' "$block" | grep -qE 'Dockerfile([^A-Za-z0-9._-]|$)'

  # A swallowed hadolint failure (`|| true`) must never come back on a command
  # line. Full-line YAML comments are ignored (they may legitimately mention it).
  run bash -c 'printf "%s\n" "$1" | grep -vE "^[[:space:]]*#" | grep -qF "|| true"' _ "$block"
  [ "$status" -ne 0 ]
}

@test "dependabot keeps github-actions and docker coverage" {
  local dep="$REPO_ROOT/.github/dependabot.yml"
  [ -f "$dep" ]
  grep -qE 'package-ecosystem:[[:space:]]*"github-actions"' "$dep"
  grep -qE 'package-ecosystem:[[:space:]]*"docker"' "$dep"
}
