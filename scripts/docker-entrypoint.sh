#!/usr/bin/env bash
# =============================================================================
# docker-entrypoint.sh — Docker mode entrypoint (tini is PID 1).
# Runs as root, then hands off to paseo-boot.sh which drops the daemon to paseo.
#
# IS_DOCKER is baked as ENV IS_DOCKER=true in the image. `docker export` does
# not carry image ENV, so a WSL distro imported from the rootfs sees it unset
# and falls through to wsl-boot.sh.
# =============================================================================
set -euo pipefail

if [ "${IS_DOCKER:-false}" != "true" ]; then
  exec /usr/local/bin/wsl-boot.sh "$@"
fi

# Ownership (B3) and the git safe.directory trust (B4) are both handled inside
# the shared paseo-boot.sh; this entrypoint only dispatches.
exec /usr/local/bin/paseo-boot.sh
