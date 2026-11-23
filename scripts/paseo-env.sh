#!/usr/bin/env bash
# =============================================================================
# paseo-env.sh — pure parsers for the paseo daemon deployment environment.
#
# Sourced by paseo-boot.sh (the daemon's bind/web-UI values) and wsl-boot.sh
# (the readiness probe URL), and by tests. It has NO side effects: no shell
# options, no output on success, and the only globals it sets are the
# documented outputs below. Invalid input returns non-zero (message on stderr).
# =============================================================================
# The documented outputs are read by the sourcing script, not this file.
# shellcheck disable=SC2034

# paseo_parse_listen <host:port>
#   Sets PASEO_LISTEN_CANONICAL, PASEO_PROBE_HOST, PASEO_PORT.
#   The daemon/config value keeps concrete binds as configured (0.0.0.0 stays
#   0.0.0.0) but canonicalizes the aliases Node cannot bind reliably: `*` ->
#   0.0.0.0 and `localhost` -> 127.0.0.1. The HEALTH PROBE for wildcards and
#   localhost is 127.0.0.1. IPv6 must be bracketed ([::1]:6767); unbracketed
#   IPv6 fails.
paseo_parse_listen() {
  local value="${1-}"
  local host port probe port_norm colons

  if [ -z "$value" ]; then
    printf 'paseo_parse_listen: empty listen value\n' >&2
    return 1
  fi
  # No whitespace anywhere, and never a socket path / URL userinfo.
  case "$value" in
    *[[:space:]]*)
      printf 'paseo_parse_listen: whitespace is not allowed\n' >&2
      return 1
      ;;
    */* | *@*)
      printf 'paseo_parse_listen: "/" and "@" are not allowed\n' >&2
      return 1
      ;;
  esac

  case "$value" in
    \[*)
      if [[ "$value" =~ ^\[([0-9A-Fa-f:.]+)\]:([^:]*)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
      else
        printf 'paseo_parse_listen: malformed bracketed IPv6 (expected [addr]:port)\n' >&2
        return 1
      fi
      case "$host" in
        *:*) ;;
        *)
          printf 'paseo_parse_listen: bracketed host must be IPv6\n' >&2
          return 1
          ;;
      esac
      probe="[$host]"
      if [ "$host" = "::" ]; then probe="[::1]"; fi
      ;;
    *)
      case "$value" in
        *'['* | *']'*)
          printf 'paseo_parse_listen: brackets only wrap IPv6 addresses\n' >&2
          return 1
          ;;
      esac
      colons="${value//[^:]/}"
      if [ "${#colons}" -ne 1 ]; then
        printf 'paseo_parse_listen: expected exactly one ":host:port" separator\n' >&2
        return 1
      fi
      host="${value%%:*}"
      port="${value#*:}"
      if [ -z "$host" ] || [ -z "$port" ]; then
        printf 'paseo_parse_listen: host and port must both be present\n' >&2
        return 1
      fi
      case "$host" in
        0.0.0.0) probe="127.0.0.1" ;;
        '*')
          probe="127.0.0.1"
          host="0.0.0.0"
          ;;
        localhost)
          probe="127.0.0.1"
          host="127.0.0.1"
          ;;
        *) probe="$host" ;;
      esac
      ;;
  esac

  case "$port" in
    '' | *[!0-9]*)
      printf 'paseo_parse_listen: port must be decimal 1..65535\n' >&2
      return 1
      ;;
  esac
  port_norm="$port"
  while [ "${port_norm#0}" != "$port_norm" ]; do
    port_norm="${port_norm#0}"
  done
  if [ -z "$port_norm" ]; then port_norm=0; fi
  if [ "${#port_norm}" -gt 5 ] ||
    [ "$port_norm" -lt 1 ] ||
    [ "$port_norm" -gt 65535 ]; then
    printf 'paseo_parse_listen: port must be decimal 1..65535\n' >&2
    return 1
  fi

  case "$value" in
    \[*) PASEO_LISTEN_CANONICAL="[$host]:$port_norm" ;;
    *) PASEO_LISTEN_CANONICAL="$host:$port_norm" ;;
  esac
  PASEO_PROBE_HOST="$probe"
  PASEO_PORT="$port_norm"
  return 0
}

# paseo_parse_web_ui <value>
#   Sets PASEO_WEB_UI_CANONICAL to exactly "true" or "false".
#   Accepts case-insensitive true|false and 1|0.
paseo_parse_web_ui() {
  local value="${1-}"

  case "${value,,}" in
    true | 1) PASEO_WEB_UI_CANONICAL="true" ;;
    false | 0) PASEO_WEB_UI_CANONICAL="false" ;;
    *)
      printf 'paseo_parse_web_ui: expected true|false|1|0\n' >&2
      return 1
      ;;
  esac
  return 0
}
