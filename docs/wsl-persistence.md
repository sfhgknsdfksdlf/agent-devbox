# WSL data persistence (VHDX data disk)

Goal: **upgrading the image (re-importing the distro) must not lose your data.**

## Model

- The distro's system disk (`ext4.vhdx` inside the install dir) holds only the
  image rootfs. Re-importing/replacing it loses nothing important.
- A **separate 32 GB dynamic VHDX** (`data.vhdx`) holds your persistent data. Its
  ext4 label and mount name are **channel-scoped**: `devbox-data` (stable) or
  `devbox-data-beta` (beta, exactly 16 characters, the ext4 limit). It is never
  touched by an upgrade.
- **Each variant × channel has its own disk in its own install dir.** The
  multi-agent `agent-devbox` (`D:\WSL\agent-devbox`) and the lean
  `agent-devbox-core` (`D:\WSL\agent-devbox-core`) are the stable channel;
  `agent-devbox-beta` (`D:\WSL\agent-devbox-beta`) and `agent-devbox-core-beta`
  (`D:\WSL\agent-devbox-core-beta`) are the beta channel. No two installs share a
  data disk, so their `/home`, `/root` and `/workspace` are separate.
- At every distro start, `wsl-boot.sh` first **attaches** the VHDX from inside the
  distro (one bounded `wsl.exe --mount --vhd <path> --bare`; skipped when the device
  is already there), then resolves the block device by UUID (`blkid -t UUID=`,
  every device carrying it), falling back to the channel's label only when no
  device carries that UUID (`devbox-data` for stable, `devbox-data-beta` for
  beta), and `mount -t ext4` it at **`/mnt/<DATA_MNTNAME>`**
  (`/mnt/devbox-data` or `/mnt/devbox-data-beta`; more than one candidate fails
  closed), then **binds** it over:
  - `/home`       (paseo state + agent config/credentials)
  - `/root`       (root's shell config)
  - `/workspace`  (your code)

  Label precedence is `AGENT_DEVBOX_DATA_LABEL` (environment) > the conf's
  `DATA_LABEL` > `devbox-data`.

```
升级前:  agent-devbox[-beta](系统盘 ext4.vhdx)  +  data.vhdx(你的 /home /root /workspace)
删掉/重装 distro  ->  data.vhdx 原封不动
重挂 data.vhdx    ->  数据回来了 ✅
```

## Who does what (important)

Creating the VHDX and initializing it is the installer's job. Attaching it from
inside the distro needs no elevation (measured), but it only survives while the WSL
VM lives. Split of responsibility:

| Who | Does |
|---|---|
| Windows installer (`irm .../windows/install.ps1 \| iex` → `install-agent-devbox.ps1`) | create + attach `data.vhdx`, initialize it (only when brand new; ext4 label `devbox-data` for stable / `devbox-data-beta` for beta), write `/etc/agent-devbox.conf` (6 keys), resolve the data-disk UUID by the channel's label before falling back to the old conf UUID (logs a swap, e.g. a copied same-channel variant disk), attach the disk itself and unregister legacy `agent-devbox*-mount-datadisk` tasks (no task is registered), copy the pure-batch `mount-datadisk.cmd` / `unmount-datadisk.cmd` helpers into the install dir |
| Image boot (`wsl-boot.sh`) | attach the VHDX itself when the device is absent (one bounded `wsl.exe --mount --vhd --bare`), locate the device by UUID (`blkid -t UUID=`) then by the channel's label (`devbox-data` / `devbox-data-beta`), fail closed on a multi-match, `mount -t ext4` at `/mnt/<DATA_MNTNAME>`, **verify** the disk, bind `/home` `/root` `/workspace`, start the daemon |

## Safety guarantees

- **Formatting happens only in `datadisk-init.sh`, invoked only by the installer
  right after it created a fresh VHDX.** The boot path never formats.
- `datadisk-init.sh` selects only a *whole disk with no partition table and no
  filesystem* that is not the root disk; if the choice is ambiguous it refuses.
  A non-zero `datadisk-init` is now **fatal**: the installer stops before writing
  `/etc/agent-devbox.conf`, so another channel's disk UUID/password can never be
  written into this channel's config. `data.vhdx` is kept for a retry.
- `wsl-boot.sh` **fails closed**: if the disk is not mounted, no attached device
  matches the UUID or the channel's label (`devbox-data` / `devbox-data-beta`),
  **more than one** device matches either, or a `/home` `/root` `/workspace`
  bind does not land on the data disk, it enters **MAINTENANCE MODE**, seeds
  nothing and starts nothing.
- `wsl-boot.sh` makes **exactly one** `wsl.exe` call, the bounded
  `--mount --vhd <path> --bare` attach (skipped when the device is already there).
  It must never call `schtasks.exe`, `wsl -d` or `--unmount`: calling Windows tools
  from `/etc/wsl.conf [boot] command` re-entered WSL and caused a boot loop
  (a blank console window closing/reopening, then the VM shutting down). Linux does
  the `mount -t ext4`.
- `/etc/agent-devbox.conf` (6 keys: `DATA_VHDX`, `DATA_UUID`, `DATA_LABEL`,
  `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_DISTRO`) is written by the installer and
  **re-injected on every install/upgrade run**.

## First-time setup (recommended)

1. Run the Windows installer one-liner (agents by default; type `c` at the
   variant prompt for the lean `core` build):

   ```powershell
   irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
   ```
2. Accept the one UAC prompt.
3. Press Enter for the default install dir (`D:\WSL\agent-devbox` for
   agents/stable, `D:\WSL\agent-devbox-core` for core/stable; a beta-channel
   install gets `D:\WSL\agent-devbox-beta` / `D:\WSL\agent-devbox-core-beta`), or
   type one. An explicit `-InstallDir` is used verbatim and never suffixed.
4. Enter a paseo password (or press Enter to generate one). Each channel keeps its
   own password.
5. The installer attaches the data disk in the same elevated session and
   unregisters any legacy `agent-devbox-mount-datadisk` /
   `agent-devbox-core-mount-datadisk` task left by an older version. No task is
   registered. Every distro start attaches the VHDX from inside the distro and
   mounts it in Linux.
6. The installer copies the manual pure-batch `mount-datadisk.cmd` /
   `unmount-datadisk.cmd` helpers into the install dir.

For a **beta-channel** install, run the same one-liner with a non-`main` ref
(`-Ref <branch>` or `$env:AGENT_DEVBOX_REF`): the default dirs become
`D:\WSL\agent-devbox-beta` / `D:\WSL\agent-devbox-core-beta`, with a separate
data disk. Changing only the URL's branch is not enough (see
`installation-wsl.md`).

The script is **idempotent** — re-run it any time to re-check/re-configure.

## Upgrade procedure

```powershell
$Distro = 'agent-devbox'   # or agent-devbox-core / agent-devbox-beta / agent-devbox-core-beta
wsl --terminate $Distro             # only this distro
wsl --unregister $Distro            # system disk gone; data.vhdx untouched
# re-run the installer with the SAME channel (imports the new rootfs and re-injects the config)
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
```

For a **beta-channel** install, re-run with the same ref, otherwise the installer
creates/uses the stable distro and your beta data disk is not picked up:

```powershell
$env:AGENT_DEVBOX_REF = 'my-branch'
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
```

`--unregister` removes only the distro's system disk (`ext4.vhdx`); the `data.vhdx`
in the install dir is untouched, so your data survives. There is no automatic
migration of a stable data disk into the beta channel (or the reverse).

Then verify:

```powershell
$env:WSL_UTF8 = 1
$Channel = 'stable'   # 'beta' for the beta channel
$names = @('agent-devbox', 'agent-devbox-core', 'agent-devbox-beta', 'agent-devbox-core-beta')
$Distro = (wsl -l -q) | ForEach-Object { ($_ -replace "`0", '').Trim() } |
  Where-Object {
    $_ -in $names -and
    (($_ -notlike '*-beta') -eq ($Channel -eq 'stable'))
  } | Select-Object -First 1
wsl -d $Distro
# then, inside the distro:
mount | grep -E 'devbox-data| /home | /root | /workspace '
ls -la ~ /workspace
```

## Verification checklist

| Check | Command | Expected |
|---|---|---|
| Data disk mounted | `mount \| grep devbox-data` | present (at `/mnt/devbox-data` or `/mnt/devbox-data-beta`) |
| `/home` from data disk | `findmnt /home` | source under `/mnt/devbox-data/home` or `/mnt/devbox-data-beta/home` |
| Manual repair entry | `mount-datadisk.cmd` in the install dir (pure batch, no UAC) | attaches `data.vhdx`; 3 attempts logged to `datadisk-attach.log`, real exit code |
| Manual detach entry | `unmount-datadisk.cmd` in the install dir (pure batch, no UAC) | detaches `data.vhdx`; an existing but not-attached disk prints `[INFO]` and exits 0; real failures stay non-zero |
| Mount survives a distro restart | `wsl --terminate $Distro` then reopen; `mount \| grep devbox-data` | attach kept; boot re-mounts it (`wsl --shutdown` only on a confirmed networking-mode change) |
| Attach re-established after a Windows restart | reboot Windows, reopen the distro | boot attaches and mounts it automatically |
| Persists across restart | write file → `wsl --terminate $Distro` → `wsl -d $Distro` | file present |
| Persists across upgrade | `--unregister` + re-import | file present |

## Automating the re-attach

The attach only survives while the WSL VM lives. `wsl --terminate <distro>` keeps
it. `wsl --shutdown` detaches **all** mounted disks by design (it closes every
distro) and is reserved for the confirmed networking-mode change. A Windows restart
**always** loses the attach, because WSL keeps its automatic re-attach state in a
**VOLATILE** registry key that a restart clears.

There is exactly one automatic path:

- **Every distro start (`wsl-boot.sh`) attaches the VHDX itself.** If the device is
  already present (preexisting attach) it skips `wsl.exe`; otherwise it makes
  **exactly one** bounded `wsl.exe --mount --vhd "<path>" --bare` call (hard
  timeout + kill grace), waits once for the device, then:
  1. if the data disk is already mounted at `/mnt/<DATA_MNTNAME>`, continue;
  2. otherwise find exactly one block device by UUID (`blkid -t UUID= <DATA_UUID>`),
     falling back to the channel's label (`devbox-data` / `devbox-data-beta`), and
     `mount -t ext4` it at
     `/mnt/<DATA_MNTNAME>` (i.e. `/mnt/devbox-data` or
     `/mnt/devbox-data-beta`); a multi-match fails closed;
  3. verify the mount, seed on first run, verify the three binds, start paseo.
  It must never call `schtasks.exe`, `wsl -d` or `--unmount` (the old boot-time
  callback re-entered WSL and caused a boot loop).
- **Windows side — manual repair only.** There is no scheduled task. The install
  dir's pure-batch `mount-datadisk.cmd` attaches the VHDX directly
  (`wsl.exe --mount --vhd "<path>" --bare`; attach-only: no `--type ext4`, no
  `--name`), retries 3×, logs `datadisk-attach.log`, and returns wsl's real exit
  code. `unmount-datadisk.cmd` detaches it; an existing but not-attached disk
  (e.g. right after a Windows reboot) is a no-op (`[INFO]`, exit 0), while a
  missing path or a real detach failure stays non-zero. Neither needs
  PowerShell or UAC.

If the boot attach fails, or the device never appears, boot enters **MAINTENANCE
MODE** (fail closed: nothing is seeded or started) and writes a bilingual
`/etc/motd` banner plus `boot failed` to the boot log. The banner prints the two
copy-pasteable repair commands:

```powershell
# in the WSL terminal (copy & paste):
cmd.exe /c "<InstallDir>\mount-datadisk.cmd"
wsl.exe --terminate <distro>

# or, in Windows PowerShell:
<InstallDir>\mount-datadisk.cmd
wsl --terminate <distro>
```

Then reopen the distro; that start mounts the disk. On a successful boot the stale
banner is cleared. `wsl-boot.sh` never auto-launches the Windows installer.

### Manual helpers

The installer copies two pure-batch helpers into the install dir (it fetches them
from the selected ref, `main` by default). Neither needs PowerShell or
administrator/UAC:

```bat
# attach <InstallDir>\data.vhdx (bare); retries 3x, logs datadisk-attach.log,
# exits with wsl's real code
mount-datadisk.cmd
# attach another VHDX (bare) via the positional path argument
mount-datadisk.cmd "D:\other\x.vhdx"
# detach (\?\<vhdx>); already detached -> [INFO], exit 0
unmount-datadisk.cmd
```

### Stopping a distro: `wsl --terminate` (and when `wsl --shutdown` is allowed)

`wsl --terminate <distro>` stops only that distro and **keeps** the attached
VHDX; the next start re-attaches it if needed and re-mounts it. `wsl --shutdown`
closes **all** distros and detaches **all** mounted disks by design; it is
reserved for exactly one case: right after `.wslconfig` `networkingMode` changed,
the installer warns that it closes every running distro and asks y/N (default No).
A Windows restart **always** loses the attach (VOLATILE registry state), but the
next start re-attaches from inside the distro automatically. Only if that boot
attach fails do you need the repair path: run `<InstallDir>\mount-datadisk.cmd`,
then `wsl --terminate <distro>`, then reopen the distro.

### Swapping data disks within a channel

The full and core data disks are interchangeable **within the same channel**:
copy one variant's `data.vhdx` into the other variant's install dir (stable
`agent-devbox` with `agent-devbox-core`, or beta `agent-devbox-beta` with
`agent-devbox-core-beta`) and it boots there. Cross-channel copies are not
supported: stable and beta use different labels and mount names, and the
installer's directory ownership valve refuses to put one channel over the other.

1. Both variants in a channel use that channel's ext4 label and mount name:
   `devbox-data` (stable) or `devbox-data-beta` (beta).
2. Boot resolves the device by UUID first (all devices carrying that UUID), and
   only when **no** device carries it does it fall back to the channel's label;
   a copied disk (which keeps the **source** UUID) still mounts
   even though it does not match the target variant's
   `/etc/agent-devbox.conf` UUID. Separate disks with different UUIDs (the two
   variants' own `data.vhdx` files) can be attached at the same time.
3. Boot does **not** rewrite the conf UUID.
4. Ambiguity is fail-closed: more than one device sharing the resolved identity
   (two same-channel copies with the same UUID, or, when the UUID is absent,
   two disks with the channel's label), boot mounts neither, logs it (`多块` in
   the boot log) and enters **MAINTENANCE MODE**. Fix: run the install dir's
   `unmount-datadisk.cmd` to detach the extra disk, then reopen the distro. There
   is no "pick the first device" fallback.
5. The installer resolves the data-disk UUID by the channel's label **before**
   falling back to the old conf UUID, and logs
   `数据盘 UUID 已变化（<old> -> <new>）：按标签 '<label>' 识别，可能是另一个变体的数据盘。`
   when it swaps — so an upgrade with a copied disk reads the password from the
   right disk.
6. Copies are independent filesystems (no sync). Copy only while the source is
   detached; `wsl --shutdown` detaches all mounted disks and is the safe pre-copy
   step, not a requirement for a normal swap.

### 故障排查：为什么同时看到 `/mnt/wsl/agent-devbox-data` 和 `/mnt/devbox-data`？

**根因**：`/mnt/wsl` 是一个**跨发行版共享**的 tmpfs。如果机器上还留着**旧发行版**或**旧版本残留
的自动挂载**，它会在自己的启动里把数据盘挂到 `/mnt/wsl/agent-devbox-data`；而当前安装用的是
`/mnt/devbox-data`（beta 通道是 `/mnt/devbox-data-beta`）。本仓库**不再**生成 `agent-devbox-data` 这个挂载名，
所以同时看到两者，通常
说明有一个旧残留（旧发行版 / 旧版本残留的挂载）仍在按老名字挂载。它们可能指向**同一块** VHDX，也可能不是，
所以**不要**直接删。

先在 WSL 里确认挂载来源：

```bash
mount | grep -E 'agent-devbox-data|devbox-data'
findmnt -T /mnt/wsl/agent-devbox-data
findmnt -T /mnt/devbox-data
cat /etc/agent-devbox.conf
```

再在 Windows 侧看发行版，以及是否还有旧版本残留的任务：

```powershell
wsl -l -v
schtasks /query /tn agent-devbox-mount-datadisk /v /fo LIST
schtasks /query /tn agent-devbox-core-mount-datadisk /v /fo LIST
```

**处理**：重跑 Windows 安装器
（`irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex`），
让它按当前配置重建挂载；或先注销那个不再用的旧发行版（`wsl --unregister <旧发行版>`），并注销
对应的旧任务（只有旧版本才会留下）。**不要**在看清 `findmnt` 指向哪块设备之前，手工删除或格式化任何目录 / 磁盘。

**换盘后进维护模式**：若 boot 日志出现 `多块`（同时匹配 UUID 或本通道的标签 `devbox-data` / `devbox-data-beta`），说明同通道的复制盘和原盘都还附加着；运行安装目录的 `unmount-datadisk.cmd` 分离多余那块，再重新打开发行版。
