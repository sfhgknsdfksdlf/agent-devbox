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
When you instead run `install-agent-devbox.ps1` directly (or use the `irm | iex`
path), the non-elevated window waits for the elevated one and echoes its full log
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
3. download the released rootfs and import it as the distro `agent-devbox`, in
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
5. create a 32 GB dynamic `data.vhdx` in the install dir and initialize it;
6. fix the VHDX owner/ACLs so a non-elevated user can reopen it;
7. write `/etc/agent-devbox.conf` (5 keys: `DATA_VHDX`, `DATA_UUID`,
   `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_TASK`);
8. **always** register the logon Scheduled Task `agent-devbox-mount-datadisk`
   (highest privileges) that re-attaches the disk; pass `-NoTask` to skip it;
9. restart the distro, and the boot script mounts the disk through a fallback
   chain (see `wsl-persistence.md`);
10. delete the downloaded parts, any merged `.zst`, and any `.tar`, after success
    and on failure.

Then: `wsl -d agent-devbox`.

See `wsl-persistence.md` for the data model, safety guarantees and upgrade steps.

## Path B — wsl-ui GUI

[wsl-ui](https://github.com/octasoft-ltd/wsl-ui) installs a distro from a
Docker/Podman image using its own OCI implementation (no Docker required):

1. Install wsl-ui (Microsoft Store or GitHub releases).
2. New Distribution → **Container Images** → reference
   `ghcr.io/sfhgknsdfksdlf/agent-devbox:latest`
   (or `.../agent-devbox-core:latest`).
3. Name it **`agent-devbox`**.

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
wsl -d agent-devbox
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
- `New-VHD` (Hyper-V module) if available, otherwise the built-in `diskpart`
  fallback creates the dynamic VHDX.
- No extra program for the import itself on the happy path: WSL2's built-in bsdtar
  decompresses the zstd stream. `zstd.exe` is only fetched as the last-resort tier.

Both `install-agent-devbox.ps1` and `import-distro.ps1` dot-source
`windows/wsl-ensure.ps1`, which holds the shared helpers (release-tag
normalization, disk-space math, streaming import, the zstd fallback, and the
distro-ready assertion).
