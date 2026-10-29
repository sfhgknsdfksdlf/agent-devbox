# Attach the persistent data disk to this login shell's mount namespace.
# WSL keeps a per-elevation namespace, so a session may not see the bind mounts
# the boot session made; re-resolve the cwd afterwards so it points at the
# freshly bound tree. This file must never abort the login shell.
[ "${IS_DOCKER:-false}" = "true" ] && return 0

case $- in *i*) ;; *) return 0 ;; esac
[ -t 0 ] || return 0
[ -r "${AGENT_DEVBOX_CONF:-/etc/agent-devbox.conf}" ] || return 0

HELPER="${AGENT_DEVBOX_SESSION_MOUNT_BIN:-/usr/local/bin/wsl-session-mount.sh}"
[ -x "$HELPER" ] || return 0

if "$HELPER"; then
  case "$PWD" in
    /home|/home/*|/root|/root/*|/workspace|/workspace/*)
      cd "$PWD" 2>/dev/null || cd "$HOME" 2>/dev/null || true
      ;;
  esac
fi

return 0
