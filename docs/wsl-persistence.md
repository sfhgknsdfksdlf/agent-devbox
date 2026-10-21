# WSL data persistence (VHDX data disk)

Goal: **upgrading the image (re-importing the distro) must not lose your data.**

## Model

- The distro's system disk (`ext4.vhdx` inside the install dir) holds only the
  image rootfs. Re-importing/replacing it loses nothing important.
- A **separate 32 GB dynamic VHDX** (`data.vhdx`, ext4 label `devbox-data`) holds
  your persistent data. It is never touched by an upgrade.
- **Each variant has its own disk in its own install dir.** The multi-agent
  `agent-devbox` (`D:\WSL\agent-devbox`) and the lean `agent-devbox-core`
  (`D:\WSL\agent-devbox-core`) do **not** share a data disk, so their `/home`,
  `/root` and `/workspace` are separate.
- At boot, `wsl-boot.sh` is **pure Linux**: it finds the already-attached block
  device by UUID (`blkid -U`) and `mount -t ext4` it at **`/mnt/devbox-data`**, then
  **binds** it over:
  - `/home`       (paseo state + agent config/credentials)
  - `/root`       (root's shell config)
  - `/workspace`  (your code)

```
升级前:  agent-devbox(系统盘 ext4.vhdx)  +  data.vhdx(你的 /home /root /workspace)
删掉/重装 distro  ->  data.vhdx 原封不动
重挂 data.vhdx    ->  数据回来了 ✅
```

## Who does what (important)

Creating and attaching a VHDX requires **Windows administrator** rights, so a
Linux process inside the distro **cannot** do it. Split of responsibility:

| Who | Does |
|---|---|
| Windows installer (`irm .../windows/install.ps1 \| iex` → `install-agent-devbox.ps1`) | create + attach `data.vhdx`, initialize it (only when brand new; ext4 label `devbox-data`), write `/etc/agent-devbox.conf`, **always** register the hidden attach-only logon Scheduled Task (`agent-devbox-mount-datadisk` / `agent-devbox-core-mount-datadisk`; use `-NoTask` to skip), copy the `mount-datadisk.*` / `unmount-datadisk.*` helpers into the install dir |
| Image boot (`wsl-boot.sh`) | pure Linux: locate the already-attached device by UUID (`blkid -U`), `mount -t ext4` at `/mnt/devbox-data`, **verify** the disk, bind `/home` `/root` `/workspace`, start the daemon |

## Safety guarantees

- **Formatting happens only in `datadisk-init.sh`, invoked only by the installer
  right after it created a fresh VHDX.** The boot path never formats.
- `datadisk-init.sh` selects only a *whole disk with no partition table and no
  filesystem* that is not the root disk; if the choice is ambiguous it refuses.
- `wsl-boot.sh` **fails closed**: if the disk is not mounted, its UUID does not
  match the expected UUID, or a `/home` `/root` `/workspace` bind does not land
  on the data disk, it enters **MAINTENANCE MODE**, seeds nothing and starts
  nothing.
- `wsl-boot.sh` **never calls `wsl.exe` / `schtasks.exe`**. Calling Windows tools
  from `/etc/wsl.conf [boot] command` re-entered WSL and caused a boot loop
  (a blank console window closing/reopening, then the VM shutting down). Windows
  only **attaches** the disk (the hidden logon task); Linux does the
  `mount -t ext4`.
- `/etc/agent-devbox.conf` (5 keys: `DATA_VHDX`, `DATA_UUID`, `PASEO_PASSWORD`,
  `DATA_MNTNAME`, `DATA_TASK`) is written by the installer and **re-injected on
  every install/upgrade run**.

## First-time setup (recommended)

1. Run the Windows installer one-liner (agents by default; type `c` at the
   variant prompt for the lean `core` build):

   ```powershell
   irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
   ```
2. Accept the one UAC prompt.
3. Press Enter for the default install dir (`D:\WSL\agent-devbox`), or type one.
4. Enter a paseo password (or press Enter to generate one).
5. The installer **always** registers the hidden, attach-only logon Scheduled Task
   (`agent-devbox-mount-datadisk` for agents, `agent-devbox-core-mount-datadisk`
   for core) that runs `wsl --mount --vhd <path> --bare`; the Linux boot script then
   does the `mount -t ext4`. Pass `-NoTask` to skip the task.
6. The installer copies the manual `mount-datadisk.cmd` / `unmount-datadisk.cmd`
   helpers (and their `.ps1`) into the install dir.

The script is **idempotent** — re-run it any time to re-check/re-configure.

## Upgrade procedure

```powershell
wsl --terminate agent-devbox             # only this distro
wsl --unregister agent-devbox            # system disk gone; data.vhdx untouched
# (use `agent-devbox-core` instead if you installed the lean variant)
# re-run the installer (imports the new rootfs and re-injects the config)
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
```

`--unregister` removes only the distro's system disk (`ext4.vhdx`); the `data.vhdx`
in the install dir is untouched, so your data survives.

Then verify:

```powershell
$Distro = (wsl -l -q) | ForEach-Object { ($_ -replace "`0", '').Trim() } |
  Where-Object { $_ -like 'agent-devbox*' } | Select-Object -First 1
wsl -d $Distro                # agent-devbox or agent-devbox-core
# then, inside the distro:
mount | grep -E 'devbox-data| /home | /root | /workspace '
ls -la ~ /workspace
```

## Verification checklist

| Check | Command | Expected |
|---|---|---|
| Data disk mounted | `mount \| grep devbox-data` | present (at `/mnt/devbox-data`) |
| `/home` from data disk | `findmnt /home` | source under `/mnt/devbox-data/home` |
| Scheduled Task registered | `schtasks /query /tn agent-devbox-mount-datadisk` (or `agent-devbox-core-mount-datadisk`) | present (RunLevel Highest, trigger AtLogOn, hidden `--bare` action) |
| Mount survives a distro restart | `wsl --terminate $Distro` then reopen; `mount \| grep devbox-data` | still attached and re-mounted by the Linux boot (`wsl --shutdown` only on a confirmed networking-mode change) |
| Persists across restart | write file → `wsl --terminate $Distro` → `wsl -d $Distro` | file present |
| Persists across upgrade | `--unregister` + re-import | file present |

## Automating the re-attach

`wsl --mount` needs admin, and the attach only survives while the WSL VM lives:
`wsl --terminate <distro>` keeps it, but a Windows restart (or `wsl --shutdown`, which
the installer only runs with explicit y/N consent after changing the networking mode) loses it — then the disk must be re-attached before the
Linux boot can mount it. The split is now strict:

- **Windows side — the only thing that touches `wsl.exe`:** the hidden, attach-only
  logon Scheduled Task (`agent-devbox-mount-datadisk` for agents,
  `agent-devbox-core-mount-datadisk` for core; RunLevel Highest, trigger AtLogOn,
  `MultipleInstances IgnoreNew`) whose action is a hidden PowerShell
  (`-WindowStyle Hidden -EncodedCommand`) running only
  `wsl --mount --vhd "<path>" --bare`. It is **attach-only**: no `--type ext4`, no
  `--name`. The hidden wrapper is what removes the blank console window; the
  installer registers it **always** (`-NoTask` opts out).
- **Linux side (`wsl-boot.sh`) — never calls `wsl.exe` / `schtasks.exe`** (the old
  boot-time callback re-entered WSL and caused a boot loop). On every boot it:
  1. if the data disk is already mounted at `/mnt/devbox-data`, continue;
  2. otherwise find the already-attached block device by UUID
     (`blkid -U <DATA_UUID>`) and `mount -t ext4` it at `/mnt/<DATA_MNTNAME>`
     (i.e. `/mnt/devbox-data`);
  3. verify the UUID, seed on first run, verify the three binds, start paseo.

If the device is not attached (for example right after a Windows restart, which
clears the attach), boot enters **MAINTENANCE MODE** (fail closed: nothing is
seeded or started) and writes a bilingual `/etc/motd` banner naming the Windows
installer one-liner
(`irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex`).
On a successful boot it clears the stale banner. `wsl-boot.sh` never auto-launches the Windows installer.

### Manual helpers

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

### Stopping a distro: `wsl --terminate` (and when `wsl --shutdown` is allowed)

`wsl --terminate <distro>` stops only that distro and **keeps** the attached
VHDX, so the next start re-mounts it. `wsl --shutdown` is reserved for exactly
one case: right after `.wslconfig` `networkingMode` changed, the installer warns
that it closes every running distro and asks y/N (default No). After a Windows restart
the attach is gone; the next start stays in MAINTENANCE MODE until the disk is
re-attached: run `mount-datadisk.cmd` in the install dir, re-run the installer,
or log off/on to fire the logon task.

### 故障排查：为什么同时看到 `/mnt/wsl/agent-devbox-data` 和 `/mnt/devbox-data`？

**根因**：`/mnt/wsl` 是一个**跨发行版共享**的 tmpfs。如果机器上还留着**旧发行版**或**旧的计划
任务**，它会在自己的启动里把数据盘挂到 `/mnt/wsl/agent-devbox-data`；而当前安装用的是
`/mnt/devbox-data`。本仓库**不再**生成 `agent-devbox-data` 这个挂载名，所以同时看到两者，通常
说明有一个旧残留（旧发行版 / 旧任务）仍在按老名字挂载。它们可能指向**同一块** VHDX，也可能不是，
所以**不要**直接删。

先在 WSL 里确认挂载来源：

```bash
mount | grep -E 'agent-devbox-data|devbox-data'
findmnt -T /mnt/wsl/agent-devbox-data
findmnt -T /mnt/devbox-data
cat /etc/agent-devbox.conf
```

再在 Windows 侧看发行版与计划任务：

```powershell
wsl -l -v
schtasks /query /tn agent-devbox-mount-datadisk /v /fo LIST
schtasks /query /tn agent-devbox-core-mount-datadisk /v /fo LIST
```

**处理**：重跑 Windows 安装器
（`irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex`），
让它按当前配置重建挂载；或先注销那个不再用的旧发行版（`wsl --unregister <旧发行版>`）并删除对应
的旧计划任务。**不要**在看清 `findmnt` 指向哪块设备之前，手工删除或格式化任何目录 / 磁盘。
