# scripts/ — runtime boot logic

## OVERVIEW
Bash that boots the environment in both modes; runs as root, copied to `/usr/local/bin` at build time, shared by Docker and WSL.

## WHERE TO LOOK
| File | Role |
|---|---|
| paseo-boot.sh | single owner: pins a sane `PATH` at the top (the WSL `[boot]` env is minimal — no `/usr/bin`, so `gosu ... env` failed with `executable file not found in $PATH` and the daemon never started); clears a **stale `$PASEO_HOME/paseo.pid`** before starting (the pidfile lives on the persistent data disk, so after a WSL/container restart it points at a dead — or reused — PID and paseo would abort with "Another Paseo daemon is already running" on every boot); drops to `paseo` and runs `paseo daemon run`; enforces `PASEO_PASSWORD`; `flock` single-instance. Sourced with `BASH_SOURCE` guard so `clear_stale_pidfile` is unit-tested by `tests/bats/paseo-boot.bats` |
| docker-entrypoint.sh | Docker dispatch: `IS_DOCKER=true` → paseo-boot, else → wsl-boot |
| wsl-boot.sh | WSL boot, **pure Linux**: if not already mounted, find the attached device by UUID (`blkid -U`) and `mount -t ext4` at `/mnt/<DATA_MNTNAME>` (i.e. `/mnt/devbox-data`), verify, bind /home /root /workspace, expose the desktop-app CLI link (`ensure_opencode_shim /root /home/*` → `~/.opencode/bin/opencode`), start daemon; **never** calls `wsl.exe` / `schtasks.exe` (that caused a boot loop); fail-closed to MAINTENANCE (writes a bilingual `/etc/motd` banner naming the Windows install one-liner on failure, clears it on success); never re-launches the installer. Its outcome is logged per home (已就绪 / 已创建 / 补充可执行位 / 保持不变) so the boot log alone answers "was the desktop link applied?". |
| datadisk-init.sh | `mkfs` only (seeding belongs to wsl-boot.sh's fail-closed first-run pass); takes the ext4 label as `$1` (validated: non-empty, `[A-Za-z0-9._-]`, ≤16 chars — ext4 caps labels at 16 chars, so an over-long label is silently truncated, which used to break the installer's `blkid -t LABEL=` fallback); called ONLY by the Windows installer |
| seed-agent-config.sh | copy missing omo/OpenCode config into a HOME (never overwrites) |
| agent-env.sh | shared PATH/GOROOT exports, sourced by login shells |
| desktop-cli-check.sh | READ-ONLY desktop/Paseo self-check: runs the OpenCode desktop's exact `$HOME/.opencode/bin/opencode` probe, compares `opencode --version` when `--expected-opencode-version` is given, verifies bash/curl (app-critical) + git (warning), resolves every CLI in `AGENT_DEVBOX_DESKTOP_CLIS` through PATH, and reports CLIs that exist only in per-user bin dirs (invisible to the daemon/login shell); never writes anything; exit 0 pass / 1 app-critical / 2 usage |

## CONVENTIONS
- All scripts: `set -euo pipefail`; shellcheck 0.9.0-clean (no `A && B || C`). **Exceptions:** `wsl-boot.sh` deliberately uses `set -uo pipefail` (no `-e`) — its boot logic is best-effort and a failed step must not abort before it logs / writes the MAINTENANCE MOTD; `desktop-cli-check.sh` uses the same for the opposite reason — every probe must report instead of aborting the run, and it never writes anything itself.
- paseo-boot: sets `HOME=/home/paseo` for the daemon ONLY; chowns top-level homes only (never recurse the mounted data disk). The daemon's pidfile is on that persistent home, so it is **validated against `/proc`** (dead or reused PID → delete) before every start.
- wsl-boot logs to **stdout only**: `/etc/wsl.conf [boot] command` already redirects into `/var/log/agent-devbox-boot.log` (`>>`), so appending in the script too wrote every line twice.
- wsl-boot: idempotent; **pure Linux** — if the data disk is not already mounted, locate the attached block device by UUID (`blkid -U`) and `mount -t ext4` it at `/mnt/<DATA_MNTNAME>` (i.e. `/mnt/devbox-data`); it NEVER calls `wsl.exe` / `schtasks.exe` (the old boot-time callback re-entered WSL and caused a boot loop). Verifies the mount with `findmnt` (+ UUID when `DATA_UUID` is set). On failure it prints MAINTENANCE MODE and writes a bilingual `/etc/motd` banner naming the Windows install one-liner (`irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex`), then exits before seeding/starting — it NEVER auto-launches the Windows installer; on success it clears the stale banner. Reads 5 keys from `/etc/agent-devbox.conf` (`DATA_VHDX`, `DATA_UUID`, `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_TASK`); its constants are env-overridable (`AGENT_DEVBOX_CONF` / `_DATADIR` / `_MNTNAME` / `_TASK` / `_LOG` / `AGENT_DEVBOX_MOTD`) so tests can source it. Logs to stdout only (`/etc/wsl.conf` already redirects into the log). After the binds it calls `ensure_opencode_shim /root /home/*`: the OpenCode DESKTOP app probes ONLY `$HOME/.opencode/bin/opencode` (no PATH lookup) and needs that path to run `serve`, but `/root` and `/home` live on the data disk, so the link is (re)created every boot; it never overwrites an existing executable CLI and never installs V2.
- seed-agent-config.sh honors `AGENT_SEED_DIR` (default `/opt/agent-seed`) so tests can point it at a temp dir.
- datadisk-init.sh refuses unless exactly one whole, partition-less, filesystem-less, non-root disk is found; it takes the ext4 label as `$1` and validates it (non-empty, `[A-Za-z0-9._-]`, ≤16 chars) before `mkfs -L`.

## ANTI-PATTERNS
- Boot scripts must NEVER format a disk.
- Boot scripts must NEVER call Windows tools (`wsl.exe` / `schtasks.exe`) — calling them from `/etc/wsl.conf [boot] command` re-entered WSL and caused a boot loop.
- Never set a global HOME; never `chown -R` over the mounted data disk.
- Never `|| true` away a check that guards user data or the password gate.
