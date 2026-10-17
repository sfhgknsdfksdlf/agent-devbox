# windows/ — WSL installer & launchers

## OVERVIEW
PowerShell that imports the released rootfs as a WSL distro and wires up a persistent data disk. No Docker needed on Windows.

## WHERE TO LOOK
| File | Role |
|---|---|
| install-agent-devbox.ps1 | full installer: import + create/attach VHDX + write `/etc/agent-devbox.conf` + optional logon task |
| import-distro.ps1 | import-only path (no data disk) |
| wsl-ensure.ps1 | dot-sourced preflight: `Ensure-Wsl` (if WSL is missing it offers base WSL vs base WSL + wsl-ui), `Test-WslInstalled`, `Install-WslUi`, mirrored-networking helpers |
| agent-devbox.bat / agent-devbox-core.bat | thin launchers (Enter = agents variant) |

## CONVENTIONS
- `$ErrorActionPreference='Stop'`; CI AST-parses every `windows/*.ps1` (ps-lint job).
- Elevates once via UAC (`Start-Process -Verb RunAs`) and re-invokes with the same params.
- Idempotent: creates only what is missing. With interactive confirmation it can re-import (replace) an existing distro to switch builds — the data-disk VHDX is never touched/reformatted.
- Download + reassemble Release parts by streaming with `Join-Parts` (`[System.IO.File]`), then decompress with a pinned `zstd.exe` fetched from the official facebook/zstd release (Windows has no built-in zstd).
- Data-disk lifecycle: `New-VHD` (diskpart fallback) → `wsl --mount --vhd --bare` → run `/usr/local/bin/datadisk-init.sh` → capture UUID → `wsl --unmount` (boot re-attaches via `wsl --mount --vhd --name`).

## ANTI-PATTERNS
- NEVER build a `cmd /c copy /b "..."` command string (quote/`$()` escaping breaks the PS parser) — use `Join-Parts`.
- NEVER format an existing data disk; re-running the installer only refreshes config.
- The interactive shell user is root; the paseo daemon runs as non-root `paseo`.
