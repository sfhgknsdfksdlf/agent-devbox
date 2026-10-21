# scripts/ — runtime boot logic

## OVERVIEW
Bash that boots the environment in both modes; runs as root, copied to `/usr/local/bin` at build time, shared by Docker and WSL.

## WHERE TO LOOK
| File | Role |
|---|---|
| paseo-boot.sh | single owner: pins a sane `PATH` at the top (the WSL `[boot]` env is minimal — no `/usr/bin`, so `gosu ... env` failed with `executable file not found in $PATH` and the daemon never started); drops to `paseo` and runs `paseo daemon run`; enforces `PASEO_PASSWORD`; `flock` single-instance |
| docker-entrypoint.sh | Docker dispatch: `IS_DOCKER=true` → paseo-boot, else → wsl-boot |
| wsl-boot.sh | WSL boot, **pure Linux**: if not already mounted, find the attached device by UUID (`blkid -U`) and `mount -t ext4` at `/mnt/<DATA_MNTNAME>` (i.e. `/mnt/devbox-data`), verify, bind /home /root /workspace, start daemon; **never** calls `wsl.exe` / `schtasks.exe` (that caused a boot loop); fail-closed to MAINTENANCE (writes a bilingual `/etc/motd` banner naming both launchers on failure, clears it on success); never re-launches the installer |
| datadisk-init.sh | `mkfs` + seed the brand-new VHDX; takes the ext4 label as `$1` (validated: non-empty, `[A-Za-z0-9._-]`, ≤16 chars — ext4 caps labels at 16 chars, so an over-long label is silently truncated, which used to break the installer's `blkid -t LABEL=` fallback); called ONLY by the Windows installer |
| seed-agent-config.sh | copy missing omo/OpenCode config into a HOME (never overwrites) |
| agent-env.sh | shared PATH/GOROOT exports, sourced by login shells |

## CONVENTIONS
- All scripts: `set -euo pipefail`; shellcheck 0.9.0-clean (no `A && B || C`). **Exception:** `wsl-boot.sh` deliberately uses `set -uo pipefail` (no `-e`) — its boot logic is best-effort and a failed step must not abort before it logs / writes the MAINTENANCE MOTD.
- paseo-boot: sets `HOME=/home/paseo` for the daemon ONLY; chowns top-level homes only (never recurse the mounted data disk).
- wsl-boot: idempotent; **pure Linux** — if the data disk is not already mounted, locate the attached block device by UUID (`blkid -U`) and `mount -t ext4` it at `/mnt/<DATA_MNTNAME>` (i.e. `/mnt/devbox-data`); it NEVER calls `wsl.exe` / `schtasks.exe` (the old boot-time callback re-entered WSL and caused a boot loop). Verifies the mount with `findmnt` (+ UUID when `DATA_UUID` is set). On failure it prints MAINTENANCE MODE and writes a bilingual `/etc/motd` banner naming both launchers (`agent-devbox.bat` / `agent-devbox-core.bat`), then exits before seeding/starting — it NEVER auto-launches the Windows installer; on success it clears the stale banner. Reads 5 keys from `/etc/agent-devbox.conf` (`DATA_VHDX`, `DATA_UUID`, `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_TASK`); its constants are env-overridable (`AGENT_DEVBOX_CONF` / `_DATADIR` / `_MNTNAME` / `_TASK` / `_LOG` / `AGENT_DEVBOX_MOTD`) so tests can source it. Logs to stdout AND `/var/log/agent-devbox-boot.log`.
- seed-agent-config.sh honors `AGENT_SEED_DIR` (default `/opt/agent-seed`) so tests can point it at a temp dir.
- datadisk-init.sh refuses unless exactly one whole, partition-less, filesystem-less, non-root disk is found; it takes the ext4 label as `$1` and validates it (non-empty, `[A-Za-z0-9._-]`, ≤16 chars) before `mkfs -L`.

## ANTI-PATTERNS
- Boot scripts must NEVER format a disk.
- Boot scripts must NEVER call Windows tools (`wsl.exe` / `schtasks.exe`) — calling them from `/etc/wsl.conf [boot] command` re-entered WSL and caused a boot loop.
- Never set a global HOME; never `chown -R` over the mounted data disk.
- Never `|| true` away a check that guards user data or the password gate.
