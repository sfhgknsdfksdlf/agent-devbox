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
project source (`main` by default, or the selected `-Ref`) and uses the Release
**only** for the rootfs parts. It asks for admin rights once and, when run interactively, asks which image to
install (Enter = the full multi-agent `agents` build, `c` = the lean `core` build)
and which release to install (Enter = `latest`, `b` = the newest beta, or paste a
specific tag).

All installer output is Chinese, and it prints a **10-step progress banner**:

```text
[1/10] 检查运行环境…   [2/10] 检查磁盘空间…   [3/10] 下载镜像…
[4/10] 导入镜像…   [5/10] 校验发行版注册…
[6/10] 创建数据磁盘（32GB 动态）…   [7/10] 初始化数据磁盘…
[8/10] 修复权限…   [9/10] 写入启动配置 /etc/agent-devbox.conf…
[10/10] 附加数据磁盘 / 清理旧版任务…   [完成] 重启发行版…
```

## Channels (stable / beta)

The installer derives the channel from the **code ref**, not from the release tag:
`beta` when `$Ref -ne 'main'`, otherwise `stable`. `$Ref` comes from `-Ref`, then
`$env:AGENT_DEVBOX_REF`, then the interactive prompt (Enter = `main`), then `main`.

> **The URL's branch is not the channel.** A plain
> `irm .../<branch>/windows/install.ps1 | iex` cannot see which branch it was
> fetched from: it installs the `main` scripts into the **stable** channel. To
> install from a branch, pass `-Ref <branch>` or set
> `$env:AGENT_DEVBOX_REF = '<branch>'`:
>
> ```powershell
> # environment variable, then the usual one-liner
> $env:AGENT_DEVBOX_REF = 'my-branch'
> irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
>
> # or pass -Ref to the entry script itself
> & ([scriptblock]::Create((irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1))) -Ref my-branch
> ```

Beta appends `-beta` to the distro name, the default install dir, the ext4 label
and the mount name (the four-row table is in step 3 below). `devbox-data-beta` is
exactly 16 characters, the ext4 label limit. Within a channel the agents and core
data disks stay interchangeable; **across channels they are not**.

An explicit `-InstallDir` is used **verbatim** and is never suffixed. A directory
is owned by exactly one channel: if it already contains `data.vhdx` **or**
`ext4.vhdx`, the installer reads `<dir>\.agent-devbox-channel` (a missing marker
means a legacy stable install) and refuses a different channel, telling you to
drop `-InstallDir` and use the channel's default dir, or choose a new directory.

Stable and beta can be installed and run at the same time: distinct distro,
install dir, `data.vhdx`, paseo password, Windows Terminal fragment
(`agent-devbox-beta.json` / `agent-devbox-core-beta.json`) and fixed GUIDs.
`%LOCALAPPDATA%\agent-devbox` staging is shared, but every run uses a random
subdirectory.

A few things stay **host-global**: `.wslconfig` (for example mirrored
networking), `Set-MirroredNetworking` and `wsl --shutdown` affect the whole
machine, so a beta install can still change the host's networking settings or
stop other distros.

Data-disk initialization is **fatal** now: an invalid label, an ambiguous
candidate disk or an `mkfs` failure aborts the install before
`/etc/agent-devbox.conf` is written, so another channel's disk UUID/password can
never be written into this channel's config. `data.vhdx` is kept for a retry.

This **channel** is not the beta **release tag**: `-ReleaseTag b|beta` selects the
newest `beta-*` GitHub prerelease (the rootfs), while `-Ref` selects the code
branch. A beta-channel install may use a stable rootfs or a beta rootfs **as long
as its `/usr/local/bin/wsl-boot.sh` supports the channel label (`DATA_LABEL`)**;
an older rootfs is refused (the just-imported distro is unregistered and
`data.vhdx` is kept) with a hint to use `-ReleaseTag beta` or a newer build.
Only refs that contain the beta-channel implementation produce the beta channel;
older tags and commits still ship the old `install.ps1` (no `-Channel`) and fall
back to the stable entry.

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
3. download the released rootfs for the host's **native** architecture (`amd64`
   or `arm64`) and import it as the WSL distro, using the **variant × channel**
   identity (an explicit `-InstallDir` is used verbatim, never suffixed):

   | variant | channel | distro | default install dir | ext4 label / mount name |
   |---|---|---|---|---|
   | agents | stable | `agent-devbox` | `D:\WSL\agent-devbox` | `devbox-data` |
   | agents | beta | `agent-devbox-beta` | `D:\WSL\agent-devbox-beta` | `devbox-data-beta` |
   | core | stable | `agent-devbox-core` | `D:\WSL\agent-devbox-core` | `devbox-data` |
   | core | beta | `agent-devbox-core-beta` | `D:\WSL\agent-devbox-core-beta` | `devbox-data-beta` |

   It imports in **three tiers** (the happy path is Tier 1; ARM64 has only Tier 1
   and Tier 2, see "ARM64 (Windows 11)"):
   - **Tier 1** streams the downloaded parts straight into
     `wsl --import <Distro> <InstallDir> -`; WSL2's built-in bsdtar decompresses
     zstd, so there is no `zstd.exe`, no merged `.zst`, and no `.tar`;
   - **Tier 2** merges the parts, then imports the `.tar.zst` by file path;
   - **Tier 3** (last resort, x64 only) downloads `zstd.exe`, decompresses to
     `.tar`, then imports.
   So the happy path never downloads `zstd.exe` on Windows 11 or Windows 10;
4. verify the distro is really registered (exact name via `wsl -l -q`, plus
   `ext4.vhdx` exists and the distro launches). On failure it unregisters the
   partial registration and exits non-zero with an actionable Chinese message,
   including the per-user caveat: WSL distros are registered per Windows user, so
   elevating via UAC into a **different** admin account makes the distro invisible
   to the original user (`WSL_E_DISTRO_NOT_FOUND`);
5. create a 32 GB dynamic `data.vhdx` in the install dir and initialize it with
   the channel-scoped ext4 label (`devbox-data` for stable, `devbox-data-beta`
   for beta; each variant × channel gets its own `data.vhdx` in its own
   install dir, so no two installs share a data disk). See
   "Creating the data disk" below for the `New-VHD` probe and the `diskpart`
   fallback;
6. fix the VHDX owner/ACLs so a non-elevated user can reopen it;
7. write `/etc/agent-devbox.conf` (6 keys: `DATA_VHDX`, `DATA_UUID`,
   `DATA_LABEL`, `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_DISTRO`);
8. **attach the disk itself** (it is already elevated) with
   `wsl --mount --vhd "<vhdx>" --bare` (attach only: no `--type ext4`, no
   `--name`), and unregister any legacy `agent-devbox-mount-datadisk` /
   `agent-devbox-core-mount-datadisk` task left by an older version. **No**
   scheduled task is registered. After the restart the installer asserts the NEW
   boot-log lines: `boot complete` passes, while `boot failed` fails immediately
   with the repair commands — it never leaves the distro in MAINTENANCE MODE
   silently. The Linux side does the actual `mount -t ext4` (see step 9). The
   installer also copies the manual pure-batch `mount-datadisk.cmd` /
   `unmount-datadisk.cmd` helpers into the install dir;
9. restart the distro. Boot (`wsl-boot.sh`) now attaches the data VHDX itself:
   unless the device is already present it makes **exactly one** bounded
   `wsl.exe --mount --vhd <path> --bare` interop call (hard timeout, kill grace),
   waits once for the device by UUID (`blkid -t UUID=`), falling back to the
   channel's label (`devbox-data` stable / `devbox-data-beta` beta), and
   `mount -t ext4` it at `/mnt/<DATA_MNTNAME>` (`/mnt/devbox-data` or
   `/mnt/devbox-data-beta`), verifies it, then binds `/home` `/root` `/workspace` and
   starts paseo. Other Windows-tool calls stay forbidden: it must never call
   `schtasks.exe` / `wsl -d` / `--unmount` (the old boot-time callback re-entered
   WSL and caused a boot loop). On failure it goes to MAINTENANCE MODE, logs
   `boot failed`, and the banner gives the repair commands for both the WSL
   terminal and Windows PowerShell. Stop the distro
   with `wsl --terminate <distro>`, which **keeps** the attach; `wsl --shutdown`
   detaches **all** mounted disks by design and is reserved for the confirmed
   networking-mode change. A Windows restart always loses the attach (WSL's
   automatic re-attach state is a VOLATILE registry key); the next start re-attaches
   from inside the distro automatically. If that boot attach fails, see
   `wsl-persistence.md` for the repair path;
10. delete the downloaded parts, any merged `.zst`, and any `.tar`, after success
    and on failure.

Then enter it. The distro name depends on **variant × channel**: `agent-devbox` /
`agent-devbox-core` (stable) or `agent-devbox-beta` / `agent-devbox-core-beta`
(beta). If you do not want to remember which one you installed, paste this once
into Windows PowerShell; it detects the install for the selected channel and
makes it the default distro:

```powershell
$env:WSL_UTF8 = 1
$Channel = 'stable'   # use 'beta' for a beta-channel install
$names = @('agent-devbox', 'agent-devbox-core', 'agent-devbox-beta', 'agent-devbox-core-beta')
$Distro = (wsl -l -q) | ForEach-Object { ($_ -replace "`0", '').Trim() } |
  Where-Object {
    $_ -in $names -and
    (($_ -notlike '*-beta') -eq ($Channel -eq 'stable'))
  } | Select-Object -First 1
if (-not $Distro) { throw "no $Channel agent-devbox found ($($names -join ' / ')) - run the installer first" }
wsl --set-default $Distro
"using distro: $Distro"
```

Every command below that starts with `wsl -d $Distro` then works in that same
PowerShell window.

See `wsl-persistence.md` for the data model, safety guarantees and upgrade steps.

## Download integrity and resume

The rootfs parts (`rootfs-<variant>-<arch>.tar.zst.part-*`, multi-GB Release
assets) are downloaded with a managed
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
the SHA256 is verified against the Release's single `SHA256SUMS` asset, which
covers the parts of both architectures. A mismatch deletes
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
cleans up the merged files. A failed import keeps this run's parts and sidecars
(unless the content was proven bad), so re-running the installer re-verifies
their SHA256 and resumes; a successful import removes this run's parts.

## ARM64 (Windows 11)

Support scope: **Windows 11 ARM64 only, build 22000 or later**. Windows 10 ARM64
is **not** supported: the installer rejects it early with a Chinese error, before
downloading anything. Distro names do not change with the architecture (the four
variant × channel names above, including `-beta` when the ref is not `main`);
only the asset names carry the architecture.

CI publishes both architectures as
`rootfs-<variant>-<arch>.tar.zst.part-*`, where `<arch>` is `amd64` or `arm64`,
plus **one** `SHA256SUMS` that covers every part of both. The installer detects
the native host architecture and picks the matching parts automatically, with no
extra flag; x64 installs are unchanged.

Inside the distro `uname -m` prints `aarch64` on ARM64 (`x86_64` on x64). After
the import, and **before** `datadisk-init.sh` runs (so before any `mkfs`), the
installer executes `uname -m` and requires the matching value: `wsl --import`
itself does **not** validate the architecture, so without this probe a wrong-arch
rootfs would only fail much later. On a mismatch, or when the rootfs cannot
execute at all (`Exec format error`), the installer unregisters the just-imported
distro, removes only its `ext4.vhdx`, keeps `data.vhdx`, leaves any already-cleaned
parts to the normal success cleanup, and throws a readable error. A re-run
re-verifies/re-downloads the parts.

Tier 3 does not exist on ARM64: the pinned `zstd.exe` is a win64 binary. ARM64
therefore has **Tier 1 (streaming) and Tier 2 (file import) only**. Skipping
Tier 3 does not mark the download as suspect (`ContentSuspect` is never set), so
the parts stay in the install dir and a retry re-verifies their SHA256 before
resuming. If both tiers fail, run `wsl --update` and re-run the installer.

An older Release that predates ARM64 support carries only
`rootfs-*-amd64` parts. On ARM64 the install fails **before any download** with
`没有 ARM64 分片` and tells you to use `-ReleaseTag latest` / `beta`, or to
install on x64. There is no amd64 fallback: WSL2 does not emulate x86-64 Linux
ELF binaries, so an amd64 rootfs cannot boot on ARM64.

Architecture detection is fail-closed, in this order:

1. `PROCESSOR_ARCHITEW6432`;
2. the **machine-scope** `PROCESSOR_ARCHITECTURE` value from the registry;
3. the process `PROCESSOR_ARCHITECTURE` environment variable;
4. CIM `Win32_Processor.Architecture` (`12` = ARM64, `9` = x64).

The machine-scope value wins deliberately: an x64-emulated PowerShell on ARM64
reports `AMD64` in its process environment, and a 32-bit (WOW64) shell reports
`x86`, while the machine value still says `ARM64`. If no source is recognisable,
the installer throws instead of assuming amd64.

QA on a real ARM64 device (replace `<distro>` with `agent-devbox`,
`agent-devbox-core`, `agent-devbox-beta` or `agent-devbox-core-beta`):

```powershell
wsl -d <distro> -u root -e uname -m
# => aarch64

wsl -d <distro> -u root -e 'wget -q -T 5 -O /dev/null http://127.0.0.1:6767/api/health'
# => exit code 0

wsl -d <distro> -u root -e "ps -o user= -C node | sort -u"
# => paseo

wsl -d <distro> -u root -e 'script -qec "echo pty-ok" /dev/null'
# => pty-ok
```

Also confirm that the boot log ends with `boot complete` and the data disk is
mounted, then re-run the installer: the data disk and the password must survive
and `uname -m` must still be `aarch64`.

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

Either path ends with the same initialized ext4 disk (label `devbox-data` for
stable, `devbox-data-beta` for beta).

Because both variants in a channel use that channel's label, their `data.vhdx`
files are interchangeable **within the same channel**: copy one into the other
variant's install dir and boot resolves the device by UUID first (every device
carrying it), then — only when no device carries that UUID — by the channel's
label (`devbox-data` / `devbox-data-beta`), so the copied disk (which keeps the
source UUID) still mounts. The two variants' own disks have different UUIDs, so
both may stay attached. **Cross-channel copies are not supported**: a stable disk
and a beta disk do not share a label or mount name, and the installer's directory
ownership check refuses to install one channel over the other. If more than one
device shares the resolved identity, boot fails closed to maintenance mode
instead of picking one — detach the extra with the install dir's
`unmount-datadisk.cmd`, then reopen the distro.

## Install log

The installer writes a **persistent** log next to the data disk in the install dir:

```text
<InstallDir>\agent-devbox-install-<yyyyMMdd-HHmmss>.log
```

That is `D:\WSL\agent-devbox\agent-devbox-install-*.log` for agents/stable,
`D:\WSL\agent-devbox-core\agent-devbox-install-*.log` for core/stable,
`D:\WSL\agent-devbox-beta\agent-devbox-install-*.log` for agents/beta and
`D:\WSL\agent-devbox-core-beta\agent-devbox-install-*.log` for core/beta. The copy
under
`%LOCALAPPDATA%\agent-devbox` is only a **temporary relay**: the original
(non-elevated) window echoes it after the elevated run finishes, then it is
deleted. Read the newest persistent one with:

```powershell
$InstallDir = 'D:\WSL\agent-devbox'   # beta: D:\WSL\agent-devbox-beta; core likewise
Get-ChildItem "$InstallDir\agent-devbox-install-*.log" |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Tail 200
```

## The paseo password

The installer **does not print the paseo password** to the console or to the
install log. It is stored only in the distro's `/etc/agent-devbox.conf`. Each
channel has its own password. Read it
back with:

```powershell
# from Windows (define $Distro first, or write agent-devbox / agent-devbox-core /
# agent-devbox-beta / agent-devbox-core-beta)
wsl -d $Distro -u root -e cat /etc/agent-devbox.conf
```

```bash
# inside the distro (do NOT prefix with wsl -d ...)
cat /etc/agent-devbox.conf
```

The data-disk copy used across upgrades lives at
`/mnt/<DATA_MNTNAME>/.paseo-password`: `/mnt/devbox-data/.paseo-password` for
stable, `/mnt/devbox-data-beta/.paseo-password` for beta.

## Antivirus prompt and the elevated window

During the run the installer may trigger an antivirus prompt: if
**Huorong (火绒) / 360 / Windows Defender** pops up, click **允许
(Allow)**. There is no task to read back or verify: the installer attaches the
disk in the same elevated session, and every later start attaches it from inside
the distro. The manual repair entry is the pure-batch `mount-datadisk.cmd`, which
logs each attempt to `datadisk-attach.log` and returns `wsl --mount`'s real exit
code.

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

Every distro start runs `wsl-boot.sh`, which first attaches the data VHDX from
inside the distro with **one** bounded `wsl.exe --mount --vhd <path> --bare` call
(no-op when the device is already attached), then mounts it in Linux. Other Windows
tools stay forbidden: `schtasks.exe`, `wsl -d` and `--unmount` must never be called
from `[boot]` (the old boot-time callback re-entered WSL and caused a boot loop).
The script finds the device by UUID (`blkid -t UUID=`, every device carrying it),
falling back to the channel's label (`devbox-data` stable / `devbox-data-beta`
beta) only when no device carries that UUID,
and refuses to pick one if more than one device matches; it
mounts it at `/mnt/<DATA_MNTNAME>` (`/mnt/devbox-data` or
`/mnt/devbox-data-beta`), verifies it and binds `/home` `/root` `/workspace`.
If the attach fails, the disk is not attached, no device matches the UUID or the
label (or several do), or a bind does not land on the data disk,
boot enters **MAINTENANCE MODE**: it seeds nothing, starts nothing, and writes a
bilingual banner to `/etc/motd` (plus `boot failed` to the boot log) with both
copy-pasteable forms:

```powershell
# in the WSL terminal (copy & paste):
cmd.exe /c "<InstallDir>\mount-datadisk.cmd"   # attach the data VHDX
wsl.exe --terminate <distro>                   # stop it so the next start re-runs boot

# or, in Windows PowerShell:
<InstallDir>\mount-datadisk.cmd
wsl --terminate <distro>
```

Then reopen the distro; that start mounts the disk.

`wsl --terminate <distro>` keeps the attach. `wsl --shutdown` detaches **all**
mounted disks by design (it closes every distro). A Windows restart always loses the
attach, because WSL keeps its automatic re-attach state in a **VOLATILE** registry
key that a restart clears.

## Manual data-disk helpers

The installer copies two pure-batch helpers into the install dir (it fetches them
from the selected ref, `main` by default). Neither needs PowerShell or
administrator/UAC:

```bat
# attach <InstallDir>\data.vhdx (bare); retries 3x, logs datadisk-attach.log,
# exits with wsl's real code
mount-datadisk.cmd
# attach another VHDX (bare) via the positional path argument
mount-datadisk.cmd "D:\other\x.vhdx"
# detach (\?\<vhdx>)
unmount-datadisk.cmd
```

## Alternative — wsl-ui GUI import

[wsl-ui](https://github.com/octasoft-ltd/wsl-ui) installs a distro from a
Docker/Podman image using its own OCI implementation (no Docker required):

1. Install wsl-ui (Microsoft Store or GitHub releases).
2. New Distribution → **Container Images** → reference
   `ghcr.io/sfhgknsdfksdlf/agent-devbox:latest`
   (or `.../agent-devbox-core:latest`).
3. Name it **`agent-devbox`** (multi-agent build) or **`agent-devbox-core`**
   (lean build). For a beta-channel install use **`agent-devbox-beta`** /
   **`agent-devbox-core-beta`** instead and pass `-Ref` (see "Channels").

Then run the `irm` one-liner above: it detects the existing distro and only
creates/attaches the data disk and writes the boot config.

## Testing a beta (pre-release) build

This section is about the beta **release tag** (`beta-*`). The beta **channel** is
a separate thing, selected by `-Ref` (see "Channels" above).

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
(or `$env:AGENT_DEVBOX_REF`) skips the prompt, and **any non-`main` ref that
contains the beta-channel implementation selects the beta channel** (separate
distro / dir / data disk, see "Channels"); older tags and commits fall back to
the stable entry.

> **Running a branch's `install.ps1` URL is not enough to select that branch.**
> The script cannot see which branch the URL pointed at, so a plain
> `irm .../<branch>/windows/install.ps1 | iex` still uses `main` and installs into
> the stable channel. Set `-Ref` (or `$env:AGENT_DEVBOX_REF`) as well. That also
> covers testing changes to `install.ps1` itself: fetch the branch URL **and**
> pass the matching ref so the sibling scripts and the channel agree.

For unattended runs pass `-ReleaseTag` (default `latest`); the fetched
`install-agent-devbox.ps1` also accepts `-Variant` directly:

```powershell
.\install-agent-devbox.ps1 -Variant agents -ReleaseTag beta
```

Every sibling is verified against `windows/SHA256SUMS` from the same ref before
it is dot-sourced. A missing manifest (legacy refs) requires the explicit
`-AllowUnverifiedScripts` switch; a manifest that does not cover a file, or a
hash mismatch, is fatal. For a reproducible **stable** install, keep the entry and
the ref on `main` and pin only the rootfs release:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1))) -ReleaseTag build-20261020.1200
```

Pinning the **code ref** to an immutable tag or commit is also possible
(`$env:AGENT_DEVBOX_REF = '<tag-or-sha>'`), but any non-`main` ref that contains
the beta-channel implementation is the beta channel: that installs beside the
stable one instead of replacing it (older tags/commits fall back to stable).

If the distro is already installed, an interactive console asks once:
**Enter = upgrade**, `n` = cancel (exit 0, nothing downloaded or unregistered).
Any other answer is re-asked once, then treated as cancel. The prompt is
skipped (the upgrade proceeds) when stdin/stdout is redirected, with `-Yes`, or
with `-KeepExisting` (keep the current install). The data disk (`/home`,
`/root`, `/workspace`) is kept,
and the **paseo password is preserved**: it is stored on the data disk at
`/mnt/<DATA_MNTNAME>/.paseo-password` (`/mnt/devbox-data` for stable,
`/mnt/devbox-data-beta` for beta; mode 600), read back during `[7/10]`, and
rewritten after the first install. (Installs that predate this get the password
migrated once from the old `/etc/agent-devbox.conf`.) `-Reinstall` is still
accepted for compatibility (an upgrade is the default), and `-Yes` stays
unattended (it now upgrades too).

> **Where the prompt shows up:** the one-liner asks in the **elevated window
> after UAC**, before `Ensure-Wsl` and before any mirrored-networking change. So
> cancelling cannot touch `.wslconfig` or shut WSL down.

The Windows Terminal profile now has a **fixed GUID**: the image disables WSL's own profile
generator (`/etc/wsl-distribution.conf` -> `[windowsterminal] enabled=false`, which would
otherwise mint a new profile GUID on every import), and the installer writes
`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\AgentDevbox\<distro>.json` with a
constant GUID, `wsl.exe -d <distro>` and `startingDirectory = \\wsl$\<distro>\root`. The
beta channel's distro names already carry `-beta` (for example `agent-devbox-beta.json`),
and each channel has its own fixed GUID. It also
deletes the stale `Fragments\Microsoft.WSL\*.json` entry for this distro. Reinstalls keep the
same profile, so per-profile customizations survive. If wsl-ui still cannot open a terminal,
close Windows Terminal and wsl-ui and reopen them.

`beta` is never promoted to `latest`.

## After installing

```powershell
wsl -d $Distro    # agent-devbox / agent-devbox-core / agent-devbox-beta / agent-devbox-core-beta
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

- Windows 11 (or a WSL build that supports `wsl --mount --vhd`). Windows 11
  ARM64 build 22000+ is supported; Windows 10 ARM64 is not.
- PowerShell (built in). The `irm` entry fetches the installer scripts from the
  project source (`main` by default, or the selected `-Ref`) with
  `Invoke-WebRequest`. The rootfs parts are fetched
  with the managed .NET HTTP client: it resolves the Windows system proxy
  (WinINET/PAC — the same proxy the browser uses), resumes with a Range request,
  shows live `MiB/s` progress, and reconnects when a transfer stalls. The final
  file length must equal the Release asset size, so a truncated part is resumed
  instead of imported. No external download tool is required.
- `New-VHD` (Hyper-V module) if available, otherwise the built-in `diskpart`
  fallback creates the dynamic VHDX.
- No extra program for the import itself on the happy path: WSL2's built-in bsdtar
  decompresses the zstd stream. `zstd.exe` is only fetched as the last-resort tier
  on x64; ARM64 skips Tier 3 entirely.
- Manual disk helpers are fetched from the project source and copied into the
  install dir: `mount-datadisk.cmd` and `unmount-datadisk.cmd` (pure batch, no
  elevation/UAC; `mount-datadisk.cmd` logs `datadisk-attach.log` and returns the
  real exit code).

The `irm` one-liner and the fetched installer use the Release **only** for the
rootfs parts; every installer script comes from the project source (the selected
ref, `main` by default). The elevated child is started with
`-ExecutionPolicy RemoteSigned` (the copy is written by the parent, so it carries
no Mark-of-the-Web and `RemoteSigned` is sufficient).

`install-agent-devbox.ps1` dot-sources `windows/wsl-ensure.ps1`, which holds the
shared helpers (release-tag normalization, disk-space math, streaming import, the
zstd fallback, and the distro-ready assertion). The download-and-execute helpers
used by that preflight (`Install-WslUi`, `Get-ZstdExeFromRelease`) live in a
separate, lazily loaded `windows/wsl-ensure-downloads.ps1`, resolved by
`Get-AgentDevboxDownloadHelperPath`. It is dot-sourced only when actually needed
(installing the wsl-ui GUI, or the last-resort `zstd.exe` tier), so the happy path
never loads it. Both files are fetched by `install.ps1`; the installer throws a
clear Chinese error if `wsl-ensure-downloads.ps1` is missing.
