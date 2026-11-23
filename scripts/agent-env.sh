#!/usr/bin/env bash
# =============================================================================
# agent-env.sh — shared environment for agent-devbox (Docker AND WSL).
# Sourced by login shells (via /etc/profile.d/agent-devbox.sh) and by launchers.
# Deliberately does NOT set HOME (the WSL root shell must keep HOME=/root).
# =============================================================================
export GOROOT=/usr/local/go

# Only derive Go dirs from a real HOME; never invent /go or /.cache when it is
# unset/empty, and never clobber values that are already configured.
if [ -z "${GOPATH:-}" ] && [ -n "${HOME:-}" ]; then
  export GOPATH="$HOME/go"
fi
if [ -z "${GOCACHE:-}" ] && [ -n "${HOME:-}" ]; then
  export GOCACHE="$HOME/.cache/go-build"
fi

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/ms-playwright}"
export CHROME_PATH="${CHROME_PATH:-/usr/local/bin/chromium}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# De-duplicate colon-separated PATH components, keeping the first occurrence and
# dropping empty ones. IFS=: means entries with spaces stay intact.
_agent_env_join_path() {
  local -a _parts=() _out=()
  local _p _q _seen
  IFS=':' read -r -a _parts <<< "$1"
  for _p in "${_parts[@]}"; do
    [ -n "$_p" ] || continue
    _seen=0
    if [ "${#_out[@]}" -gt 0 ]; then
      for _q in "${_out[@]}"; do
        if [ "$_q" = "$_p" ]; then
          _seen=1
          break
        fi
      done
    fi
    if [ "$_seen" -eq 0 ]; then
      _out+=("$_p")
    fi
  done
  local IFS=':'
  printf '%s' "${_out[*]}"
}

_agent_env_prefix="/usr/local/go/bin:/usr/local/bin"
if [ -n "${GOPATH:-}" ]; then
  _agent_env_prefix="/usr/local/go/bin:$GOPATH/bin:/usr/local/bin"
fi
_agent_env_path="$(_agent_env_join_path "$_agent_env_prefix:${PATH:-}")"
export PATH="$_agent_env_path"
unset _agent_env_prefix _agent_env_path
unset -f _agent_env_join_path
