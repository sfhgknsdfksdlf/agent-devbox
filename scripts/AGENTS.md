# scripts/ — runtime boot logic

## OVERVIEW
Bash that boots the environment in both modes; runs as root, copied to `/usr/local/bin` at build time, shared by Docker and WSL.

## WHERE TO LOOK
| File | Role |
|---|---|
| paseo-boot.sh | single owner: drops to `paseo` and runs `paseo daemon run`; enforces `PASEO_PASSWORD`; `flock` single-instance |
| docker-entrypoint.sh | Docker dispatch: `IS_DOCKER=true` → paseo-boot, else → wsl-boot |
| wsl-boot.sh | WSL boot: attach + verify VHDX, bind /home /root /workspace, start daemon; fail-closed |
| datadisk-init.sh | `mkfs` + seed the brand-new VHDX; called ONLY by the Windows installer |
| seed-agent-config.sh | copy missing omo/OpenCode config into a HOME (never overwrites) |
| agent-env.sh | shared PATH/GOROOT exports, sourced by login shells |

## CONVENTIONS
- All scripts: `set -euo pipefail`; shellcheck 0.9.0-clean (no `A && B || C`).
- paseo-boot: sets `HOME=/home/paseo` for the daemon ONLY; chowns top-level homes only (never recurse the mounted data disk).
- wsl-boot: idempotent; verifies the mount with `findmnt` (+ UUID when `DATA_UUID` is set); on failure prints MAINTENANCE MODE and exits before seeding/starting.
- seed-agent-config.sh honors `AGENT_SEED_DIR` (default `/opt/agent-seed`) so tests can point it at a temp dir.
- datadisk-init.sh refuses unless exactly one whole, partition-less, filesystem-less, non-root disk is found.

## ANTI-PATTERNS
- Boot scripts must NEVER format a disk.
- Never set a global HOME; never `chown -R` over the mounted data disk.
- Never `|| true` away a check that guards user data or the password gate.
