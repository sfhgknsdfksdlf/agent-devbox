#!/usr/bin/env bash
# =============================================================================
# datadisk-init.sh — initialize the agent-devbox VHDX data disk.
#
# Called ONLY by the Windows installer, right after it created a FRESH VHDX and
# attached it with `wsl --mount --vhd <path> --bare` (so it appears as a bare
# whole disk). Never called from the boot path.
#
# SAFETY: picks only a WHOLE disk (no partition table, no filesystem) that is
# not the root disk. If the choice is ambiguous it refuses to format.
# =============================================================================
set -euo pipefail
LABEL=agent-devbox-data

# Identify the root disk (so we never touch it).
root_src="$(findmnt -rno SOURCE /)"
root_pk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)"
root_disk="${root_pk:-$(basename "$root_src")}"

candidates=()
while read -r dev; do
  [ -b "$dev" ] || continue
  [ "$(basename "$dev")" = "$root_disk" ] && continue
  # whole disk only (no partitions)
  [ "$(lsblk -rno NAME "$dev" | wc -l)" -eq 1 ] || continue
  # no existing filesystem
  blkid "$dev" >/dev/null 2>&1 && continue
  candidates+=("$dev")
done < <(lsblk -rndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "SKIP: no uninitialized whole disk found (already initialized?)."
  exit 0
fi
if [ "${#candidates[@]}" -gt 1 ]; then
  echo "FATAL: ambiguous candidate disks: ${candidates[*]}. Refusing to format." >&2
  exit 1
fi

DEV="${candidates[0]}"
echo "Initializing data disk $DEV with label $LABEL"
mkfs.ext4 -F -L "$LABEL" "$DEV"

mkdir -p /mnt/agent-init
mount "$DEV" /mnt/agent-init
mkdir -p /mnt/agent-init/home /mnt/agent-init/root /mnt/agent-init/workspace
tar -C /home --numeric-owner -cf - . 2>/dev/null | tar -C /mnt/agent-init/home --numeric-owner -xpf - || true
tar -C /root --numeric-owner -cf - . 2>/dev/null | tar -C /mnt/agent-init/root --numeric-owner -xpf - || true
touch /mnt/agent-init/.initialized
umount /mnt/agent-init

echo "Data disk initialized (label=$LABEL, dev=$DEV)"
echo "UUID=$(blkid -s UUID -o value "$DEV")"
