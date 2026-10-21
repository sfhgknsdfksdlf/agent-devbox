# scripts/ — runtime boot logic

## OVERVIEW
Bash that boots the environment in both modes; runs as root, copied to `/usr/local/bin` at build time, shared by Docker and WSL.

## WHERE TO LOOK
| File | Role |
|---|---|
| paseo-boot.sh | single owner: drops to `paseo` and runs `paseo daemon run`; enforces `PASEO_PASSWORD`; `flock` single-instance |
| docker-entrypoint.sh | Docker dispatch: `IS_DOCKER=true` → paseo-boot, else → wsl-boot |
| wsl-boot.sh | WSL boot: best-effort mount chain (Scheduled Task → `--mount --type ext4` → `--bare`+`blkid -U`+manual mount) for the VHDX, bind /home /root /workspace, start daemon; fail-closed to MAINTENANCE; never re-launches the installer |
| datadisk-init.sh | `mkfs` + seed the brand-new VHDX; called ONLY by the Windows installer |
| seed-agent-config.sh | copy missing omo/OpenCode config into a HOME (never overwrites) |
| agent-env.sh | shared PATH/GOROOT exports, sourced by login shells |

## CONVENTIONS
- All scripts: `set -euo pipefail`; shellcheck 0.9.0-clean (no `A && B || C`). **Exception:** `wsl-boot.sh` deliberately uses `set -uo pipefail` (no `-e`) — its mount chain is best-effort and a failed step must not abort before it logs / writes the MAINTENANCE MOTD.
- paseo-boot: sets `HOME=/home/paseo` for the daemon ONLY; chowns top-level homes only (never recurse the mounted data disk).
- wsl-boot: idempotent; a best-effort mount chain (Scheduled Task via `schtasks /run` → direct `wsl.exe --mount --type ext4` → `--bare` + `blkid -U` + manual `mount -t ext4`); verifies the mount with `findmnt` (+ UUID when `DATA_UUID` is set). On failure it prints MAINTENANCE MODE, tells the user to run `agent-devbox.bat`, and exits before seeding/starting — it NEVER auto-launches the Windows installer. Reads 5 keys from `/etc/agent-devbox.conf` (`DATA_VHDX`, `DATA_UUID`, `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_TASK`); its constants are env-overridable (`AGENT_DEVBOX_CONF` / `_DATADIR` / `_MNTNAME` / `_TASK` / `_LOG`) so tests can source it. Logs to stdout AND `/var/log/agent-devbox-boot.log`.
- seed-agent-config.sh honors `AGENT_SEED_DIR` (default `/opt/agent-seed`) so tests can point it at a temp dir.
- datadisk-init.sh refuses unless exactly one whole, partition-less, filesystem-less, non-root disk is found.

## ANTI-PATTERNS
- Boot scripts must NEVER format a disk.
- Never set a global HOME; never `chown -R` over the mounted data disk.
- Never `|| true` away a check that guards user data or the password gate.
