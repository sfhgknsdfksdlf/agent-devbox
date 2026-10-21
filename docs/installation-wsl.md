# WSL installation (Windows)

Two ways to get the image into WSL. Both need **no Docker on Windows**.

## Path A — one-click script (fully automatic, recommended)

Get **`agent-devbox-windows.zip`** from the **[latest Release](https://github.com/sfhgknsdfksdlf/agent-devbox/releases/latest)** — one download containing everything below (the `.bat` launchers and `install-agent-devbox.ps1`).

Then double-click one of (these launchers are **non-interactive** — each already
passes its own `-Variant`; running `install-agent-devbox.ps1` directly, or via the
`irm | iex` path, instead *asks* which image to install):

- `agent-devbox.bat` — the **default, multi-agent** image
- `agent-devbox-core.bat` — the lean base image

The `.bat` launcher re-launches itself elevated (one UAC prompt); the original
window closes, so only the elevated window remains, and it prints the whole 10-step
log and `pause`s at the end (success or failure) so the result stays on screen.
When you instead run `install-agent-devbox.ps1` directly (or use the `install.cmd`
bootstrap path), the non-elevated window waits for the elevated one and echoes its full log
plus a final summary and exit code, so the result is visible where you started.
All installer prompts are Chinese, and it prints a **10-step progress banner**:

```text
[1/10] 检查运行环境…   [2/10] 检查磁盘空间…   [3/10] 下载镜像…
[4/10] 导入镜像…   [5/10] 校验发行版注册…
[6/10] 创建数据磁盘（32GB 动态）…   [7/10] 初始化数据磁盘…
[8/10] 修复权限…   [9/10] 写入启动配置 /etc/agent-devbox.conf…
[10/10] 注册开机自动挂载计划任务…   [完成] 重启发行版…
```

What it does:

1. make sure WSL2 is installed — if it is missing it asks whether to install
   **base WSL only** or **base WSL + the [wsl-ui](https://github.com/octasoft-ltd/wsl-ui) GUI** (default);
2. **check free disk space before downloading anything.** It reads the compressed
   part sizes from the Release API, parses the uncompressed size straight from the
   first part's zstd frame header over a byte-range HTTP request (no download), and
   aborts with a Chinese error if the target volume is too small. The formula is
   `required = base + 2 GiB data-disk reserve + max(3 GiB, 10% of base)`, where for
   the streaming tier `base = C + V` with `C` = compressed parts and
   `V` = uncompressed × 1.05 (the `ext4.vhdx` grows on demand; its 1 TiB size is
   virtual). It is re-run if the installer falls back to a tier with a higher peak;
3. download the released rootfs and import it as the WSL distro — `agent-devbox`
   for the multi-agent build, `agent-devbox-core` for the lean build — with a
   **per-variant default install dir** (`D:\WSL\agent-devbox` for agents,
   `D:\WSL\agent-devbox-core` for core), in
   **three tiers** (the happy path is Tier 1):
   - **Tier 1** streams the downloaded parts straight into
     `wsl --import <Distro> <InstallDir> -`; WSL2's built-in bsdtar decompresses
     zstd, so there is no `zstd.exe`, no merged `.zst`, and no `.tar`;
   - **Tier 2** merges the parts, then imports the `.tar.zst` by file path;
   - **Tier 3** (last resort) downloads `zstd.exe`, decompresses to `.tar`, then
     imports.
   So the happy path never downloads `zstd.exe` on Windows 11 or Windows 10;
4. verify the distro is really registered (exact name via `wsl -l -q`, plus
   `ext4.vhdx` exists and the distro launches). On failure it unregisters the
   partial registration and exits non-zero with an actionable Chinese message,
   including the per-user caveat: WSL distros are registered per Windows user, so
   elevating via UAC into a **different** admin account makes the distro invisible
   to the original user (`WSL_E_DISTRO_NOT_FOUND`);
5. create a 32 GB dynamic `data.vhdx` in the install dir and initialize it with
   the ext4 label `devbox-data` (each variant gets its own `data.vhdx` in its own
   install dir; the two variants do **not** share a data disk);
6. fix the VHDX owner/ACLs so a non-elevated user can reopen it;
7. write `/etc/agent-devbox.conf` (5 keys: `DATA_VHDX`, `DATA_UUID`,
   `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_TASK`);
8. **always** register the hidden, **attach-only** logon Scheduled Task
   (`agent-devbox-mount-datadisk` for agents, `agent-devbox-core-mount-datadisk`
   for core; highest privileges) whose action is a **hidden** PowerShell
   (`-WindowStyle Hidden -EncodedCommand`) that runs only
   `wsl --mount --vhd "<vhdx>" --bare` (no `--type ext4`, no `--name`), with
   `MultipleInstances IgnoreNew`; pass `-NoTask` to skip it. The hidden wrapper is
   what removes the blank console window. The Linux side does the actual
   `mount -t ext4` (see step 9). The installer also copies the manual
   `mount-datadisk.cmd` / `unmount-datadisk.cmd` helpers (and their `.ps1`) into
   the install dir;
9. restart the distro. Boot (`wsl-boot.sh`) is now **pure Linux** and never calls
   `wsl.exe` / `schtasks.exe` (the old boot-time callback re-entered WSL and caused
   a boot loop). It finds the already-attached block device by UUID (`blkid -U`)
   and `mount -t ext4` it at `/mnt/devbox-data`, verifies it, then binds `/home`
   `/root` `/workspace` and starts paseo; on failure it goes to MAINTENANCE MODE.
   Caveat: `wsl --shutdown` detaches the VHDX, so the next start stays in
   MAINTENANCE until the disk is re-attached (run `mount-datadisk.cmd` in the
   install dir, re-run the installer, or log off/on to fire the logon task) — see
   `wsl-persistence.md`;
10. delete the downloaded parts, any merged `.zst`, and any `.tar`, after success
    and on failure.

Then: `wsl -d agent-devbox` (agents) or `wsl -d agent-devbox-core` (core).

See `wsl-persistence.md` for the data model, safety guarantees and upgrade steps.

## Path B — wsl-ui GUI

[wsl-ui](https://github.com/octasoft-ltd/wsl-ui) installs a distro from a
Docker/Podman image using its own OCI implementation (no Docker required):

1. Install wsl-ui (Microsoft Store or GitHub releases).
2. New Distribution → **Container Images** → reference
   `ghcr.io/sfhgknsdfksdlf/agent-devbox:latest`
   (or `.../agent-devbox-core:latest`).
3. Name it **`agent-devbox`** (multi-agent build) or **`agent-devbox-core`**
   (lean build).

Then run the data-disk part via the script (double-click `agent-devbox.bat`; it
detects the existing distro and only creates/attaches the data disk and writes
the boot config).

## Path C — scripted import only (you manage the VHDX)

`windows/import-distro.ps1` only downloads + imports the released rootfs (the same
three-tier import: stream the parts, else merge then import by file, else
`zstd.exe` to `.tar`) and runs `wsl --import`. It does not set up the data disk.

## Path D — one-line command

```powershell
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
```

Runs the same installer end to end: asks for admin rights once, installs WSL and suggests mirrored networking, downloads the latest Release zip, runs it, then cleans up its temp files. Run interactively it also asks which image to install (Enter = the full multi-agent `agents` build, `c` = the lean `core` build) and which release to install (Enter = `latest`, `b` = the newest beta).

## Testing a beta (pre-release) build

Every `push` publishes a **dated** `beta-<YYYYMMDD.HHMM>` prerelease carrying
the WSL rootfs + the Windows zip + the 1Panel zip, and moves the **`:beta`**
image alias to the newest push build. Older `beta-*` prereleases are pruned, so
only the newest survives (each is ~4.7GB). Pushes never touch `latest`.

When run interactively the installer **asks which release to install**:

```text
选择版本 [回车 = 正式版(latest)，b = beta 测试版，或输入版本号，例如 build-20261018.0731 / beta-20261018.0731]
```

Press Enter for stable (`latest`), type `b` (or `beta`) for the newest `beta-*`
prerelease (resolved through the GitHub API), or paste a specific release tag —
`build-<YYYYMMDD.HHMM>` / `beta-<YYYYMMDD.HHMM>`; a bare `YYYYMMDD.HHMM` is
resolved to `build-<YYYYMMDD.HHMM>`. For unattended runs pass `-ReleaseTag`
(default `latest`), also supported by `import-distro.ps1`:

```powershell
.\install-agent-devbox.ps1 -Variant agents -ReleaseTag beta
```

If the distro is already installed, the installer then asks whether to
**re-import** it with the chosen build. The prompt is `[Y/n]`, so Enter means
**yes, reinstall**; the data disk (`/home`, `/root`, `/workspace`) is kept, so you
can switch builds freely. For unattended runs `-Reinstall` forces the reinstall,
while `-Yes` stays idempotent (no reinstall unless `-Reinstall` is also passed).

`beta` is never promoted to `latest`.

## After installing

```bash
wsl -d agent-devbox          # multi-agent build; use agent-devbox-core for the lean build
# root shell; paseo daemon configured on http://localhost:6767 (from Windows)
```

To reach paseo from your **phone**, expose 6767 from Windows:

```powershell
netsh interface portproxy add v4tov4 listenport=6767 listenaddress=0.0.0.0 `
  connectport=6767 connectaddress=<WSL-IP>   # from `wsl hostname -I`
New-NetFirewallRule -DisplayName "agent-devbox 6767" -Direction Inbound -LocalPort 6767 -Protocol TCP -Action Allow
```

or enable mirrored networking (`%UserProfile%\.wslconfig` → `[wsl2] networkingMode=mirrored`).

## Requirements

- Windows 11 (or a WSL build that supports `wsl --mount --vhd`).
- PowerShell (built in) for `install.cmd`: it downloads the installer scripts from
  the project source (`main`) with `Invoke-WebRequest`. The rootfs parts are fetched
  with the OS's `curl.exe` (resume + retries), falling back to `Invoke-WebRequest`
  when `curl.exe` is unavailable.
- `New-VHD` (Hyper-V module) if available, otherwise the built-in `diskpart`
  fallback creates the dynamic VHDX.
- No extra program for the import itself on the happy path: WSL2's built-in bsdtar
  decompresses the zstd stream. `zstd.exe` is only fetched as the last-resort tier.
- Manual disk helpers ship in the Windows zip and the installer copies them into the
  install dir: `mount-datadisk.cmd` / `mount-datadisk.ps1` and
  `unmount-datadisk.cmd` / `unmount-datadisk.ps1` (each self-elevates once).

Both `install.cmd` and `install.ps1` fetch the installer scripts from the project
source (`main`) and use the Release ONLY for the rootfs parts. `install.ps1`'s elevated
child copy is started with `-ExecutionPolicy RemoteSigned` (the copy is written by the
parent, so it carries no Mark-of-the-Web and `RemoteSigned` is sufficient).

Both `install-agent-devbox.ps1` and `import-distro.ps1` dot-source
`windows/wsl-ensure.ps1`, which holds the shared helpers (release-tag
normalization, disk-space math, streaming import, the zstd fallback, and the
distro-ready assertion). The download-and-execute helpers used by that preflight
(`Install-WslUi`, `Get-ZstdExeFromRelease`) live in a separate, lazily loaded
`windows/wsl-ensure-downloads.ps1`, resolved by `Get-AgentDevboxDownloadHelperPath`.
It is dot-sourced only when actually needed (installing the wsl-ui GUI, or the
last-resort `zstd.exe` tier), so the happy path never loads it. Keep both files
together when extracting the release zip; the installer throws a clear Chinese
error if `wsl-ensure-downloads.ps1` is missing.
