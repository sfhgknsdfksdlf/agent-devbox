#!/usr/bin/env bash
# =============================================================================
# wsl-boot.sh — WSL2 boot script, run as root from /etc/wsl.conf [boot] command.
#
# Responsibilities (idempotent):
#   1. Ensure the VHDX data disk is attached and mounted at /mnt/wsl/<name>.
#   2. VERIFY the disk identity (mountpoint + optional UUID) — fail closed.
#   3. First-run: seed /home, /root, /workspace onto the data disk.
#   4. Bind /home, /root and /workspace onto the data disk.
#   5. Start the paseo daemon as `paseo` (single owner, backgrounded).
#
# It NEVER formats a disk. Formatting happens only in datadisk-init.sh, which is
# invoked by the Windows installer for a freshly created VHDX.
# =============================================================================
set -uo pipefail

DATADIR=/mnt/wsl/agent-devbox-data
MNTNAME=agent-devbox-data
CONF=/etc/agent-devbox.conf

log() { echo "[wsl-boot $(date -Is)] $*"; }

# --- load installer-written config (VHDX path + expected UUID + password) -----
DATA_VHDX=""; DATA_UUID=""; PASEO_PASSWORD=""
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
export PASEO_PASSWORD 2>/dev/null || true

wsl_exe() {
  if command -v wsl.exe >/dev/null 2>&1; then command -v wsl.exe; 
  elif [ -x /mnt/c/Windows/System32/wsl.exe ]; then echo /mnt/c/Windows/System32/wsl.exe; fi
}

is_mounted() { findmnt -rn --mountpoint "$DATADIR" >/dev/null 2>&1; }

# --- 1) attach the data disk if needed ----------------------------------------
if ! is_mounted; then
  WEXE="$(wsl_exe || true)"
  if [ -n "$DATA_VHDX" ] && [ -n "$WEXE" ]; then
    log "attaching data disk: $DATA_VHDX"
    "$WEXE" --mount --vhd "$DATA_VHDX" --name "$MNTNAME" || true
    for _ in $(seq 1 30); do is_mounted && break; sleep 1; done
  fi
fi

# --- 2) verify; fail closed ---------------------------------------------------
if ! is_mounted; then
  log "FATAL: data disk is not mounted at $DATADIR"
  cat >/etc/motd <<'EOF'
*** agent-devbox is in MAINTENANCE MODE ***
The data disk (VHDX) is not mounted, so nothing was seeded or started.
Run the Windows one-click installer (agent-devbox.bat) to create/attach it.
EOF
  # First-boot convenience: auto-copy the bundled Windows helper to C:\agent-devbox
  # and launch it once (one UAC prompt). Marker prevents repeat attempts.
  if [ ! -e /var/.agent-devbox-setup-invoked ]; then
    WEXE="$(wsl_exe || true)"
    if [ -n "$WEXE" ] && [ -d /mnt/c ]; then
      log "first boot with no data disk: invoking the Windows installer once"
      mkdir -p /mnt/c/agent-devbox
      cp -f /opt/agent-devbox/windows/* /mnt/c/agent-devbox/ 2>/dev/null || true
      PS="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
      if [ -x "$PS" ]; then
        "$PS" -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\agent-devbox\install-agent-devbox.ps1'" >/dev/null 2>&1 || true
      fi
      touch /var/.agent-devbox-setup-invoked
    fi
  fi
  exit 0
fi
if [ -n "${DATA_UUID:-}" ]; then
  cur="$(findmnt -rno UUID --mountpoint "$DATADIR" 2>/dev/null || true)"
  if [ "$cur" != "$DATA_UUID" ]; then
    log "FATAL: data disk UUID mismatch (found='$cur' expected='$DATA_UUID')"
    exit 0
  fi
fi

# --- 3) first-run seed (marker-based) ----------------------------------------
if [ ! -e "$DATADIR/.initialized" ]; then
  log "first run: seeding data disk"
  mkdir -p "$DATADIR/home" "$DATADIR/root" "$DATADIR/workspace"
  [ -n "$(ls -A "$DATADIR/home"    2>/dev/null)" ] || tar -C /home --numeric-owner -cf - . 2>/dev/null | tar -C "$DATADIR/home"     --numeric-owner -xpf - || true
  [ -n "$(ls -A "$DATADIR/root"    2>/dev/null)" ] || tar -C /root --numeric-owner -cf - . 2>/dev/null | tar -C "$DATADIR/root"     --numeric-owner -xpf - || true
  touch "$DATADIR/.initialized"
fi

# --- 4) bind mounts (idempotent) ---------------------------------------------
mountpoint -q /home      || mount --bind "$DATADIR/home"      /home
mountpoint -q /root      || mount --bind "$DATADIR/root"      /root
mountpoint -q /workspace || mount --bind "$DATADIR/workspace" /workspace
chmod 0700 /root

# --- 5) start the daemon as paseo (single owner) -----------------------------
if [ -f /run/agent-devbox-paseo.pid ] && kill -0 "$(cat /run/agent-devbox-paseo.pid)" 2>/dev/null; then
  log "paseo daemon already running"
else
  log "starting paseo daemon"
  setsid /usr/local/bin/paseo-boot.sh >>/var/log/paseo-boot.log 2>&1 &
  echo $! > /run/agent-devbox-paseo.pid
fi

log "boot complete"
