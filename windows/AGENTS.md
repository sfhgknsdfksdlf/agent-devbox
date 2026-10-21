# windows/ — WSL installer & launchers

## OVERVIEW
PowerShell that imports the released rootfs as a WSL distro and wires up a persistent data disk. No Docker needed on Windows.

## WHERE TO LOOK
| File | Role |
|---|---|
| install-agent-devbox.ps1 | full installer: Chinese 10-step banner (step `[2/10]` is the disk-space pre-check); tiered import (stream into `wsl --import -` → merge → `zstd.exe`); post-import registration assert; create/attach VHDX + fix ACLs + write the 5-key `/etc/agent-devbox.conf` + **always** register the logon task (`-NoTask` skips); asks core-vs-agents when interactive; dot-sources `wsl-ensure.ps1` |
| install.ps1 | `irm \| iex` web entry: asks the release + image variant when interactive, self-elevates (log-relay), downloads the Windows zip, runs the preflight + bundled installer. UTF-8 **without** BOM (see below) |
| import-distro.ps1 | import-only path (no data disk): the same tiered import; dot-sources `wsl-ensure.ps1` |
| wsl-ensure.ps1 | dot-sourced preflight **and** shared helpers: `Ensure-Wsl`/`Test-WslInstalled`/`Install-WslUi`/mirrored-networking, plus `Normalize-ReleaseTag`, `Resolve-YesNoDefault`, `Test-ZstdBanner`, `Get-NativeZstdSupport`, `Quote-NativeArg`, `Join-Parts`, `Get-FreeDiskSpaceBytes`, `Get-ZstdUncompressedSize`/`FromBytes`/`FromUrl`, `Get-RequiredDiskBytes`, `Test-DiskSpace`, `Assert-DiskSpace`, `Invoke-WslImportStream`, `Get-ZstdExe`, `Assert-DistroReady` |
| agent-devbox.bat / agent-devbox-core.bat | thin **non-interactive** launchers (each passes its own `-Variant`); self-elevate via `fltmc` + `Start-Process -Verb RunAs` on the `.bat` itself; always `pause` at the end (success or failure) |

## CONVENTIONS
- `$ErrorActionPreference='Stop'`; CI AST-parses every `windows/*.ps1` (ps-lint job).
- **Encoding/BOM policy (CI ps-lint enforces):** `install.ps1` is UTF-8 **WITHOUT** a BOM — a BOM survives `irm` as U+FEFF and breaks `iex` on PS 5.1. Every other `windows/*.ps1` (read via `-File`) is UTF-8 **WITH** a BOM — PS 5.1 reads a BOM-less file as ANSI and would garble the Chinese. The `.bat` launchers are ASCII-only (Chinese lives in the `.ps1`).
- All user-facing installer text is **Chinese**; `install-agent-devbox.ps1` prints a 10-step banner (`[1/10] 检查运行环境` … `[2/10] 检查磁盘空间` … `[10/10] 注册开机自动挂载计划任务` + `[完成] 重启发行版`). CI's ps-lint also enforces the BOM rules and the installer invariants (disk check present, `[Y/n]` not `[y/N]`, streaming import present, elevation uses `-Wait`).
- Elevates once via UAC. `install-agent-devbox.ps1` re-invokes itself with the same params; the elevated window writes its full transcript (`-LogPath`, plus a `<log>.rc` exit-code file) and the **original** window waits, then echoes the whole log plus a final summary and exit code, so the result is visible where the user started. The `.bat` launchers re-launch the `.bat` elevated and always `pause` at the end (success or failure).
- Image picker (Chinese): running `install.ps1` (`irm | iex`) or `install-agent-devbox.ps1` directly and interactively asks core vs agents (Enter = 完整版/多助手 `agents`, `c`/`core` = 精简版 `core`). The two `.bat` launchers never ask (each pins `-Variant`).
- Version picker (Chinese): Enter = `latest`, `b`/`beta` = newest `beta-*` prerelease (resolved via the GitHub API), a bare `YYYYMMDD.HHMM` = `build-<ts>`, or an explicit tag (`build-…` / `beta-…`).
- Idempotent: creates only what is missing. Re-running with an existing distro asks whether to re-import it; the prompt is `[Y/n]` so Enter means **reinstall**. `-Reinstall` forces it for unattended runs; `-Yes` stays idempotent (no reinstall unless `-Reinstall`). The data-disk VHDX is never touched/reformatted.
- Disk-space pre-check runs **before** any download (`Assert-DiskSpace`, step `[2/10]`): `required = base + 2 GiB data-disk reserve + max(3 GiB, 10% of base)`; the streaming tier uses `base = C + V` (`C` = compressed parts, `V` = uncompressed × 1.05; the `ext4.vhdx` grows on demand). The uncompressed size is parsed from the zstd frame header (local byte read, or an 18-byte HTTP Range request for the remote part). Re-run whenever it falls back to a higher-peak tier.
- Import is tiered: **Tier 1** streams the downloaded parts straight into `wsl --import <Distro> <InstallDir> -` (no `zstd.exe`, no merged `.zst`, no `.tar`; WSL2's bsdtar decodes zstd), **Tier 2** `Join-Parts` then imports the `.tar.zst` by file path, **Tier 3** (last resort) fetches a pinned `zstd.exe` and decompresses to `.tar`. The happy path never downloads `zstd.exe` on Windows 11 or 10.
- After import, `Assert-DistroReady` asserts the distro is really registered (exact name via `wsl -l -q`, `ext4.vhdx` exists, it launches); on failure it unregisters the partial registration and throws a Chinese message with the per-user caveat (UAC into a different admin account = `WSL_E_DISTRO_NOT_FOUND`). Parts / merged `.zst` / `.tar` are cleaned up on success and failure.
- Shared helpers live in `wsl-ensure.ps1` (side-effect-free, no `param()` block), dot-sourced by `install-agent-devbox.ps1` and `import-distro.ps1`; the pure ones are unit-tested by `tests/powershell/run.ps1`.
- Data-disk lifecycle: `New-VHD` (diskpart fallback) → `wsl --mount --vhd --bare` → run `/usr/local/bin/datadisk-init.sh` → capture UUID → `wsl --unmount`. Writes 5 keys to `/etc/agent-devbox.conf` (`DATA_VHDX`, `DATA_UUID`, `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_TASK`) and **always** registers the logon task `agent-devbox-mount-datadisk` (`RunLevel Highest`, `AtLogOn`, action `wsl.exe --mount --vhd "<path>" --type ext4 --name agent-devbox-data`); `-NoTask` skips it. Boot re-attaches via the fallback chain in `wsl-boot.sh`.

## ANTI-PATTERNS
- NEVER build a `cmd /c copy /b "..."` command string (quote/`$()` escaping breaks the PS parser) — use `Join-Parts`.
- NEVER move the disk-space check (`Assert-DiskSpace`) after the download; the ps-lint tripwire enforces disk-check-before-download.
- NEVER make the happy path download `zstd.exe`: Tier 1 streaming into `wsl --import -` must be tried first, and `zstd.exe` is the last-resort tier only.
- NEVER default the reinstall prompt to no (`[y/N]`); Enter must mean reinstall (`[Y/n]`), and `-Yes` must stay idempotent (no reinstall unless `-Reinstall`).
- NEVER leave the installer's output only in the elevated window; the log relay must echo it back to the original window, and the `.bat` launchers must `pause` so the result stays on screen.
- NEVER format an existing data disk; re-running the installer only refreshes config.
- NEVER add a BOM to `install.ps1` (breaks `irm | iex` on PS 5.1); NEVER strip the BOM from the other `windows/*.ps1` (PS 5.1 `-File` would garble the Chinese).
- NEVER add non-ASCII to the `.bat` launchers — Chinese belongs in the `.ps1` (cmd reads a BOM-less `.bat` as ANSI).
- NEVER build a second elevation path — the `.bat` self-elevate and the `.ps1` self-invoke are the only ones.
- The interactive shell user is root; the paseo daemon runs as non-root `paseo`.
