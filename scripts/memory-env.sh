#!/usr/bin/env bash
# =============================================================================
# memory-env.sh — export OPENCODE_MEMORY_ENDPOINT / OPENCODE_MEMORY_API_KEY from
# the per-UID runtime the supervisor published.
#
# Source this file (do not exec it) before an OpenCode-capable process starts.
# It is safe under `set -euo pipefail`: a missing endpoint/key only warns and
# leaves the variables unset. The API key is never printed.
#
# Target identity comes from AGENT_DEVBOX_MEMORY_UID / AGENT_DEVBOX_MEMORY_HOME
# (the boot scripts set them for the paseo user) or, when absent, the current
# uid and $HOME (interactive login shells). Positional parameters are deliberately
# ignored: `source file` inherits the caller's "$@", which a login shell may fill.
# =============================================================================

_agent_memory_env_load() {
  local uid home runtime endpoint_file key_file endpoint key

  uid="${AGENT_DEVBOX_MEMORY_UID:-}"
  home="${AGENT_DEVBOX_MEMORY_HOME:-}"
  if [ -z "$uid" ]; then
    uid="$(id -u 2>/dev/null || true)"
  fi
  if [ -z "$home" ]; then
    home="${HOME:-}"
  fi

  if [ -n "${AGENT_DEVBOX_MEMORY_RUNTIME_DIR:-}" ]; then
    runtime="$AGENT_DEVBOX_MEMORY_RUNTIME_DIR"
  elif [ -n "$uid" ]; then
    runtime="${AGENT_DEVBOX_MEMORY_RUNTIME_ROOT:-/run/agent-memory}/$uid"
  else
    runtime=""
  fi

  endpoint_file="$runtime/endpoint"
  key_file="$home/.local/share/mcp-memory/api-key"

  if [ -z "$runtime" ] || [ -z "$home" ] \
    || [ ! -r "$endpoint_file" ] || [ ! -r "$key_file" ]; then
    printf 'WARN: agent memory is not running for uid=%s; OPENCODE_MEMORY_ENDPOINT/OPENCODE_MEMORY_API_KEY not exported (looked for %s and %s)\n' \
      "${uid:-?}" "$endpoint_file" "$key_file" >&2
    return 0
  fi

  endpoint="$(head -n 1 -- "$endpoint_file" 2>/dev/null || true)"
  key="$(head -n 1 -- "$key_file" 2>/dev/null || true)"
  if [ -z "$endpoint" ] || [ -z "$key" ]; then
    printf 'WARN: agent memory state is incomplete for uid=%s; OPENCODE_MEMORY_ENDPOINT/OPENCODE_MEMORY_API_KEY not exported\n' \
      "${uid:-?}" >&2
    return 0
  fi

  OPENCODE_MEMORY_ENDPOINT="$endpoint"
  OPENCODE_MEMORY_API_KEY="$key"
  export OPENCODE_MEMORY_ENDPOINT OPENCODE_MEMORY_API_KEY
  return 0
}

_agent_memory_env_load
