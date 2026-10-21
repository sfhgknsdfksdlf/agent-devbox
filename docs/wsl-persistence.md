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
| Windows installer (`agent-devbox.bat` / `agent-devbox-core.bat` → `install-agent-devbox.ps1`) | create + attach `data.vhdx`, initialize it (only when brand new; ext4 label `devbox-data`), write `/etc/agent-devbox.conf`, **always** register the hidden attach-only logon Scheduled Task (`agent-devbox-mount-datadisk` / `agent-devbox-core-mount-datadisk`; use `-NoTask` to skip), copy the `mount-datadisk.*` / `unmount-datadisk.*` helpers into the install dir |
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

1. Double-click `agent-devbox.bat` (default = multi-agent) or
   `agent-devbox-core.bat`.
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
wsl --shutdown
wsl --unregister agent-devbox            # system disk gone; data.vhdx untouched
# (use `agent-devbox-core` instead if you installed the lean variant)
# re-run the installer (imports the new rootfs and re-injects the config)
.\agent-devbox.bat
```

`--unregister` removes only the distro's system disk (`ext4.vhdx`); the `data.vhdx`
in the install dir is untouched, so your data survives.

Then verify:

```bash
wsl -d agent-devbox           # or agent-devbox-core
mount | grep -E 'devbox-data| /home | /root | /workspace '
ls -la ~ /workspace
```

## Verification checklist

| Check | Command | Expected |
|---|---|---|
| Data disk mounted | `mount \| grep devbox-data` | present (at `/mnt/devbox-data`) |
| `/home` from data disk | `findmnt /home` | source under `/mnt/devbox-data/home` |
| Scheduled Task registered | `schtasks /query /tn agent-devbox-mount-datadisk` (or `agent-devbox-core-mount-datadisk`) | present (RunLevel Highest, trigger AtLogOn, hidden `--bare` action) |
| Mount is per-boot | `wsl --shutdown` then reopen; `mount \| grep devbox-data` | re-attached by the logon task (or run `mount-datadisk.cmd`), then `mount -t ext4` by the Linux boot |
| Persists across restart | write file → `wsl --shutdown` → `wsl -d agent-devbox` (attach first if needed) | file present |
| Persists across upgrade | `--unregister` + re-import | file present |

## Automating the re-attach

`wsl --mount` needs admin, and the attach is volatile (`wsl --shutdown` detaches
the VHDX), so the disk must be re-attached after every shutdown and before the
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

If the device is not attached (for example right after `wsl --shutdown`, which
cleared the attach), boot enters **MAINTENANCE MODE** (fail closed: nothing is
seeded or started) and writes a bilingual `/etc/motd` banner naming both launchers
(`agent-devbox.bat` / `agent-devbox-core.bat`). On a successful boot it clears the
stale banner. `wsl-boot.sh` never auto-launches the Windows installer.

### Manual helpers

The installer copies four helpers into the install dir (they also ship in the
Windows zip):

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

### `wsl --shutdown` caveat

`wsl --shutdown` detaches the mounted VHDX. The next distro start therefore goes
to MAINTENANCE MODE until the disk is re-attached: run `mount-datadisk.cmd` in
the install dir, re-run the installer, or log off/on to fire the logon task.
