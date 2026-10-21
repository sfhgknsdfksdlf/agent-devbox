# WSL installation (Windows)

Import the image into WSL as a distro. **No Docker is needed on Windows.**

## The only entry point — the `irm` one-liner

Open PowerShell on Windows and run:

```powershell
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
```

This is the **only** install entry point. There is nothing to download by hand and
no launcher to double-click: `install.ps1` fetches the kept installer scripts
(`install-agent-devbox.ps1`, `wsl-ensure.ps1`, `wsl-ensure-downloads.ps1`) from the
project source (`main`) and uses the Release **only** for the rootfs parts. It
asks for admin rights once and, when run interactively, asks which image to
install (Enter = the full multi-agent `agents` build, `c` = the lean `core` build)
and which release to install (Enter = `latest`, `b` = the newest beta, or paste a
specific tag).

All installer output is Chinese, and it prints a **10-step progress banner**:

```text
[1/10] 检查运行环境…   [2/10] 检查磁盘空间…   [3/10] 下载镜像…
[4/10] 导入镜像…   [5/10] 校验发行版注册…
[6/10] 创建数据磁盘（32GB 动态）…   [7/10] 初始化数据磁盘…
[8/10] 修复权限…   [9/10] 写入启动配置 /etc/agent-devbox.conf…
[10/10] 注册开机自动挂载计划任务…   [完成] 重启发行版…
```

## What the installer does

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
   install dir; the two variants do **not** share a data disk). See
   "Creating the data disk" below for the `New-VHD` probe and the `diskpart`
   fallback;
6. fix the VHDX owner/ACLs so a non-elevated user can reopen it;
7. write `/etc/agent-devbox.conf` (5 keys: `DATA_VHDX`, `DATA_UUID`,
   `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_TASK`);
8. **always** register the hidden, **attach-only** logon Scheduled Task
   (`agent-devbox-mount-datadisk` for agents, `agent-devbox-core-mount-datadisk`
   for core; highest privileges) whose action runs the install dir's
   **hidden** `mount-datadisk.ps1` (`-WindowStyle Hidden -File`). The helper
   retries the attach 3×, writes every `wsl --mount` exit code to
   `datadisk-attach.log`, and exits with the real code, so a failed attach is no
   longer reported as success. It only ever runs
   `wsl --mount --vhd "<vhdx>" --bare` (no `--type ext4`, no `--name`), with
   `MultipleInstances IgnoreNew`; pass `-NoTask` to skip the task. The installer
   **also attaches the disk itself** (it is already elevated) and, after the
   restart, polls until `/mnt/devbox-data` is mounted — it now fails loudly
   instead of leaving the distro in MAINTENANCE MODE. The Linux side does the
   actual `mount -t ext4` (see step 9). The installer also copies the manual
   `mount-datadisk.*` / `unmount-datadisk.*` helpers into the install dir;
9. restart the distro. Boot (`wsl-boot.sh`) is now **pure Linux** and never calls
   `wsl.exe` / `schtasks.exe` (the old boot-time callback re-entered WSL and caused
   a boot loop). It finds the already-attached block device by UUID (`blkid -U`)
   and `mount -t ext4` it at `/mnt/devbox-data`, verifies it, then binds `/home`
   `/root` `/workspace` and starts paseo; on failure it goes to MAINTENANCE MODE.
   Stop it with `wsl --terminate <distro>` (`wsl --shutdown` is reserved for the
   confirmed networking-mode change, because it kills every distro). Only a Windows restart loses the attach;
   the next start then stays in MAINTENANCE until the disk is re-attached (run
   `mount-datadisk.cmd` in the install dir, re-run the installer, or log off/on to
   fire the logon task) — see `wsl-persistence.md`;
10. delete the downloaded parts, any merged `.zst`, and any `.tar`, after success
    and on failure.

Then enter it. The distro name depends on the variant: `agent-devbox` (agents) or
`agent-devbox-core` (core). If you do not want to remember which one you installed,
paste this once into Windows PowerShell — it detects the variant and makes it the
default distro:

```powershell
$env:WSL_UTF8 = 1
$Distro = (wsl -l -q) | ForEach-Object { ($_ -replace "`0", '').Trim() } |
  Where-Object { $_ -like 'agent-devbox*' } | Select-Object -First 1
if (-not $Distro) { throw 'no agent-devbox / agent-devbox-core found - run the installer first' }
wsl --set-default $Distro
"using distro: $Distro"
```

Every command below that starts with `wsl -d $Distro` then works in that same
PowerShell window.

See `wsl-persistence.md` for the data model, safety guarantees and upgrade steps.

## Download integrity and resume

The rootfs parts are multi-GB Release assets downloaded with a managed
`System.Net.Http.HttpClient` (it honours the Windows system proxy, including PAC;
no external download tool is used anywhere in `windows/*.ps1`). Two things make a
resume safe:

- **Identity sidecar.** Every part gets `<InstallDir>\.agent-devbox-download\<part>.meta`
  recording the URL, the strong ETag, the expected length and (when the Release
  publishes it) the expected SHA256. A partial file with **no** sidecar, or one
  recorded for a *different* URL / size / digest, is deleted and downloaded again.
  This matters because the part filenames are identical across releases: a leftover
  9 MiB from an older tag would otherwise be resumed with the new tag's bytes and
  produce a file with the correct length but mixed content.
- **Conditional resume with `If-Match`.** A resume sends `Range` **and**
  `If-Match: <stored ETag>`. Measured on GitHub Releases: a stale `If-Range` still
  returns `206` (the header is ignored by the Azure-backed CDN), while a stale
  `If-Match` correctly returns `412`; on `412` the file restarts from zero. A `206`
  whose `Content-Range` does not start exactly at the local size is also discarded.

After the transfer the length is checked with the output handle closed, and then
the SHA256 is verified against the Release's `SHA256SUMS` asset. A mismatch deletes
the file (and its sidecar) and re-downloads once. CI publishes `SHA256SUMS`
alongside the parts; older Releases without it still install, but the installer
warns once that only the length can be checked. A manifest that **exists but does
not cover every part** is treated as an error (it would otherwise silently
downgrade that part to a length-only check).

Progress is **one line rewritten in place** at the download position every
~2 seconds, e.g. `[##########----------]  45.2%  1,006/1,900 MiB  22.2 MiB/s`
(carriage return, not `Write-Progress`, which draws in a separate region at the
top of the console and never reaches the transcript). When the output is
redirected (file/log), the same text is emitted as one normal line per tick so
the install log still carries progress records.

If an import tier fails, the installer now prints the native `wsl.exe` / `zstd.exe`
output instead of discarding it, removes a stale `<InstallDir>\ext4.vhdx` left by
the failed import (only when `wsl -l -q` succeeded and the distro is absent — an
unknown listing counts as registered, so a live disk is never touched), and
deletes this run's parts, so simply re-running the installer starts from a clean
download.

## Creating the data disk: `New-VHD` probe and `diskpart` fallback

Creating the 32 GB dynamic `data.vhdx` needs a VHDX-creation API. The installer
first probes `Get-Command New-VHD`:

- if the **Hyper-V PowerShell module** is present, it calls
  `New-VHD -Dynamic` to create the disk;
- if it is **absent**, the installer says so accurately (it does **not** guess
  "Windows Home Edition") and falls back to the built-in **`diskpart`**. The
  fallback checks the `diskpart` exit code and then verifies that a
  **non-empty `data.vhdx`** was actually produced, so a silent failure does not
  get mistaken for success.

Either path ends with the same initialized ext4 disk (label `devbox-data`).

## Install log

The installer writes a **persistent** log next to the data disk in the install dir:

```text
<InstallDir>\agent-devbox-install-<yyyyMMdd-HHmmss>.log
```

That is `D:\WSL\agent-devbox\agent-devbox-install-*.log` for agents and
`D:\WSL\agent-devbox-core\agent-devbox-install-*.log` for core. The copy under
`%LOCALAPPDATA%\agent-devbox` is only a **temporary relay**: the original
(non-elevated) window echoes it after the elevated run finishes, then it is
deleted. Read the newest persistent one with:

```powershell
Get-ChildItem 'D:\WSL\agent-devbox\agent-devbox-install-*.log' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Tail 200
```

## The paseo password

The installer **does not print the paseo password** to the console or to the
install log. It is stored only in the distro's `/etc/agent-devbox.conf`. Read it
back with:

```powershell
# from Windows (define $Distro first, or write agent-devbox / agent-devbox-core)
wsl -d $Distro -u root -e cat /etc/agent-devbox.conf
```

```bash
# inside the distro (do NOT prefix with wsl -d ...)
cat /etc/agent-devbox.conf
```

## Antivirus prompt and the elevated window

After registering the Scheduled Task the installer prints a warning: if
**Huorong (火绒) / 360 / Windows Defender** pops up a prompt, click **允许
(Allow)**. Once the task is registered the installer reads it **back** with
`Get-ScheduledTask` (verifying its `mount-datadisk.ps1` action) and checks
`Get-ScheduledTaskInfo`, so a silently dropped registration is caught instead of
reported as success. The task's own result is meaningful too: the helper exits
with `wsl --mount`'s code and logs each attempt to `datadisk-attach.log`.

Because `irm | iex` fetches the script in memory, there is no Mark-of-the-Web, so
the elevated child runs with `-ExecutionPolicy RemoteSigned` rather than the
stronger `Bypass` signal. When the run is interactive and `-Yes` was **not**
passed, the elevated window holds for about **10 seconds** at the end so you can
read the final summary before it closes.

## Logs

```powershell
# WSL boot log (data-disk mount / bind verification / MAINTENANCE mode)
wsl -d $Distro -u root -e tail -n 200 /var/log/agent-devbox-boot.log

# MAINTENANCE mode banner
wsl -d $Distro -u root -e cat /etc/motd

# paseo service log
wsl -d $Distro -u root -e tail -n 200 /var/log/paseo-boot.log

# Docker mode
docker compose logs -f

# CI (GitHub Actions)
gh run list --workflow build.yml --limit 5
gh run view <run-id> --log
```

Inside the distro, drop the `wsl -d $Distro -u root -e` prefix.

### `WSL_E_DISTRO_NOT_FOUND` when opening the terminal from wsl-ui

A reinstall/upgrade **unregisters and re-imports** the distro, so WSL assigns it a
**new GUID** (the name stays the same). wsl-ui and Windows Terminal may still hold
the **old GUID**, which produces
`Wsl/Service/CreateInstance/ReadDistroConfig/WSL_E_DISTRO_NOT_FOUND`. The distro
itself is fine: if `wsl -d $Distro` works, registration is healthy.

1. Run the `$Distro` block above (`wsl --set-default` is optional - the installer never changes your default distro).
2. In wsl-ui, **Sync / refresh** that distro, or remove the stale entry and add it
   again.
3. Still broken: close wsl-ui and Windows Terminal, clear wsl-ui's display-only
   cache, reopen:

```powershell
Stop-Process -Name wsl-ui -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\wsl-ui\distro-metadata.json" -Force -ErrorAction SilentlyContinue
```

4. The installer owns exactly one WT profile: a fixed-GUID fragment under
   `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\AgentDevbox\`. If wsl-ui cannot
   open a terminal, check that file exists (re-run the installer to recreate it), then
   close Windows Terminal and wsl-ui and reopen them. Do not hand-edit `settings.json`.

## Maintenance mode (fail closed)

`wsl-boot.sh` is pure Linux and never calls `wsl.exe` / `schtasks.exe` (the old
boot-time callback re-entered WSL and caused a boot loop). It locates the
already-attached block device by UUID (`blkid -U`), mounts it at
`/mnt/devbox-data`, verifies it and binds `/home` `/root` `/workspace`. If the
disk is not attached, the UUID does not match, or a bind does not land on the
data disk, boot enters **MAINTENANCE MODE**: it seeds nothing, starts nothing, and
writes a bilingual reminder to `/etc/motd` telling you to re-run the Windows
installer:

```powershell
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
```

Only a Windows restart detaches the mounted VHDX (`wsl --shutdown` is only used
right after a confirmed networking-mode change); the next start then goes to
MAINTENANCE until the disk is re-attached.

## Manual data-disk helpers

The installer copies four helpers into the install dir (it fetches them from the
project source, `main`):

```powershell
# attach <InstallDir>\data.vhdx (bare); self-elevates once
.\mount-datadisk.cmd
# attach another VHDX (bare)
.\mount-datadisk.cmd -Vhdx "D:\other\x.vhdx"
# attach + auto-mount at /mnt/wsl/mydisk (--type ext4 --name mydisk)
.\mount-datadisk.cmd -Vhdx "D:\other\x.vhdx" -Name mydisk
# detach (\?\<vhdx>); self-elevates once
.\unmount-datadisk.cmd
```

`.cmd` and `.ps1` variants exist for each.

## Alternative — wsl-ui GUI import

[wsl-ui](https://github.com/octasoft-ltd/wsl-ui) installs a distro from a
Docker/Podman image using its own OCI implementation (no Docker required):

1. Install wsl-ui (Microsoft Store or GitHub releases).
2. New Distribution → **Container Images** → reference
   `ghcr.io/sfhgknsdfksdlf/agent-devbox:latest`
   (or `.../agent-devbox-core:latest`).
3. Name it **`agent-devbox`** (multi-agent build) or **`agent-devbox-core`**
   (lean build).

Then run the `irm` one-liner above: it detects the existing distro and only
creates/attaches the data disk and writes the boot config.

## Testing a beta (pre-release) build

Every `push` publishes a **dated** `beta-<YYYYMMDD.HHMM>` prerelease carrying the
WSL rootfs parts + the 1Panel zip, and moves the **`:beta`** image alias to the
newest push build. Older `beta-*` prereleases are pruned, so only the newest
survives (each is ~4.7GB). Pushes never touch `latest`.

When run interactively the installer **asks which release to install**:

```text
选择版本 [回车 = 正式版(latest)，b = beta 测试版，或输入版本号，例如 build-20261018.0731 / beta-20261018.0731]
```

Press Enter for stable (`latest`), type `b` (or `beta`) for the newest `beta-*`
prerelease (resolved through the GitHub API), or paste a specific release tag —
`build-<YYYYMMDD.HHMM>` / `beta-<YYYYMMDD.HHMM>`; a bare `YYYYMMDD.HHMM` is
resolved to `build-<YYYYMMDD.HHMM>`. The installer then asks which **code ref**
to fetch the installer scripts from (Enter = `main`; `?` lists the repository
branches; a branch, tag, or commit can be typed):

```text
选择代码分支 [回车 = main，? = 列出全部分支，或输入分支名/commit]
```

Branch testing does **not** need a new image build: the scripts come from the
selected ref, while the rootfs still comes from the selected Release. `-Ref`
(or `$env:AGENT_DEVBOX_REF`) skips the prompt. Note that the picker switches the
sibling scripts; the elevated re-fetch also uses the ref, but to test changes to
`install.ps1` itself, run that branch's `install.ps1` URL. For unattended runs
pass `-ReleaseTag` (default `latest`); the fetched `install-agent-devbox.ps1`
also accepts `-Variant` directly:

```powershell
.\install-agent-devbox.ps1 -Variant agents -ReleaseTag beta
```

Every sibling is verified against `windows/SHA256SUMS` from the same ref before
it is dot-sourced. A missing manifest (legacy refs) requires the explicit
`-AllowUnverifiedScripts` switch; a manifest that does not cover a file, or a
hash mismatch, is fatal. For a reproducible production install, fetch both the
entry and `-Ref` from the same immutable tag/commit:

```powershell
$env:AGENT_DEVBOX_REF = 'build-20261020.1200'
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/build-20261020.1200/windows/install.ps1 | iex
```

Use a `build-*` tag for stable installs, or a commit SHA; branch testing keeps
using `-Ref`.

If the distro is already installed it is **upgraded in place with no prompt**
(no `y`/Enter question). The data disk (`/home`, `/root`, `/workspace`) is kept,
and the **paseo password is preserved**: it is stored on the data disk at
`/mnt/devbox-data/.paseo-password` (mode 600), read back during `[7/10]`, and
rewritten after the first install. (Installs that predate this get the password
migrated once from the old `/etc/agent-devbox.conf`.) Use `-KeepExisting` to leave the current install untouched;
`-Reinstall` is still accepted for compatibility (an upgrade is the default), and
`-Yes` stays unattended (it now upgrades too).

The Windows Terminal profile now has a **fixed GUID**: the image disables WSL's own profile
generator (`/etc/wsl-distribution.conf` -> `[windowsterminal] enabled=false`, which would
otherwise mint a new profile GUID on every import), and the installer writes
`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\AgentDevbox\<distro>.json` with a
constant GUID, `wsl.exe -d <distro>` and `startingDirectory = \\wsl$\<distro>\root`. It also
deletes the stale `Fragments\Microsoft.WSL\*.json` entry for this distro. Reinstalls keep the
same profile, so per-profile customizations survive. If wsl-ui still cannot open a terminal,
close Windows Terminal and wsl-ui and reopen them.

`beta` is never promoted to `latest`.

## After installing

```powershell
wsl -d $Distro    # $Distro = agent-devbox (multi-agent) or agent-devbox-core (lean)
# root shell; paseo daemon configured on http://localhost:6767 (from Windows)
```

Desktop apps that attach to this distro look for their CLI in a specific place, so
where it was installed decides whether they find it. See
[desktop-cli-detection.md](desktop-cli-detection.md) for the rules per app; to check
the current install read-only from Windows:
`wsl -d $Distro -u root -e desktop-cli-check.sh --home /root --also-home /home/paseo`.

To reach paseo from your **phone**, expose 6767 from Windows:

```powershell
netsh interface portproxy add v4tov4 listenport=6767 listenaddress=0.0.0.0 `
  connectport=6767 connectaddress=<WSL-IP>   # from `wsl hostname -I`
New-NetFirewallRule -DisplayName "agent-devbox 6767" -Direction Inbound -LocalPort 6767 -Protocol TCP -Action Allow
```

or enable mirrored networking (`%UserProfile%\.wslconfig` → `[wsl2] networkingMode=mirrored`).

## Requirements

- Windows 11 (or a WSL build that supports `wsl --mount --vhd`).
- PowerShell (built in). The `irm` entry fetches the installer scripts from the
  project source (`main`) with `Invoke-WebRequest`. The rootfs parts are fetched
  with the managed .NET HTTP client: it resolves the Windows system proxy
  (WinINET/PAC — the same proxy the browser uses), resumes with a Range request,
  shows live `MiB/s` progress, and reconnects when a transfer stalls. The final
  file length must equal the Release asset size, so a truncated part is resumed
  instead of imported. No external download tool is required.
- `New-VHD` (Hyper-V module) if available, otherwise the built-in `diskpart`
  fallback creates the dynamic VHDX.
- No extra program for the import itself on the happy path: WSL2's built-in bsdtar
  decompresses the zstd stream. `zstd.exe` is only fetched as the last-resort tier.
- Manual disk helpers are fetched from the project source and copied into the
  install dir: `mount-datadisk.cmd` / `mount-datadisk.ps1` and
  `unmount-datadisk.cmd` / `unmount-datadisk.ps1` (each self-elevates once).

The `irm` one-liner and the fetched installer use the Release **only** for the
rootfs parts; every installer script comes from the project source (`main`). The
elevated child is started with `-ExecutionPolicy RemoteSigned` (the copy is
written by the parent, so it carries no Mark-of-the-Web and `RemoteSigned` is
sufficient).

`install-agent-devbox.ps1` dot-sources `windows/wsl-ensure.ps1`, which holds the
shared helpers (release-tag normalization, disk-space math, streaming import, the
zstd fallback, and the distro-ready assertion). The download-and-execute helpers
used by that preflight (`Install-WslUi`, `Get-ZstdExeFromRelease`) live in a
separate, lazily loaded `windows/wsl-ensure-downloads.ps1`, resolved by
`Get-AgentDevboxDownloadHelperPath`. It is dot-sourced only when actually needed
(installing the wsl-ui GUI, or the last-resort `zstd.exe` tier), so the happy path
never loads it. Both files are fetched by `install.ps1`; the installer throws a
clear Chinese error if `wsl-ensure-downloads.ps1` is missing.
