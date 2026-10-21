# WSL data persistence (VHDX data disk)

Goal: **upgrading the image (re-importing the distro) must not lose your data.**

## Model

- The distro's system disk (`ext4.vhdx` inside the install dir) holds only the
  image rootfs. Re-importing/replacing it loses nothing important.
- A **separate 32 GB dynamic VHDX** (`data.vhdx`, label `agent-devbox-data`)
  holds your persistent data. It is never touched by an upgrade.
- At boot, `wsl-boot.sh` mounts `data.vhdx` at `/mnt/wsl/agent-devbox-data`
  through a best-effort fallback chain (see *Automating the re-attach*) and
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
| Windows installer (`agent-devbox.bat` → `install-agent-devbox.ps1`) | create + attach `data.vhdx`, initialize it (only when brand new), write `/etc/agent-devbox.conf`, **always** register the logon Scheduled Task (use `-NoTask` to skip) |
| Image boot (`wsl-boot.sh`) | run the fallback mount chain, **verify** the disk, bind `/home` `/root` `/workspace`, start the daemon |

## Safety guarantees

- **Formatting happens only in `datadisk-init.sh`, invoked only by the installer
  right after it created a fresh VHDX.** The boot path never formats.
- `datadisk-init.sh` selects only a *whole disk with no partition table and no
  filesystem* that is not the root disk; if the choice is ambiguous it refuses.
- `wsl-boot.sh` **fails closed**: if the disk is not mounted, its UUID does not
  match the expected UUID, or a `/home` `/root` `/workspace` bind does not land
  on the data disk, it enters **MAINTENANCE MODE**, seeds nothing and starts
  nothing.
- `/etc/agent-devbox.conf` (5 keys: `DATA_VHDX`, `DATA_UUID`, `PASEO_PASSWORD`,
  `DATA_MNTNAME`, `DATA_TASK`) is written by the installer and **re-injected on
  every install/upgrade run**.

## First-time setup (recommended)

1. Double-click `agent-devbox.bat` (default = multi-agent) or
   `agent-devbox-core.bat`.
2. Accept the one UAC prompt.
3. Press Enter for the default install dir (`D:\WSL\agent-devbox`), or type one.
4. Enter a paseo password (or press Enter to generate one).
5. The installer **always** registers the logon Scheduled Task
   `agent-devbox-mount-datadisk` that re-attaches the disk (the boot script also
   runs a fallback chain in case the task is absent). Pass `-NoTask` to skip the
   task.

The script is **idempotent** — re-run it any time to re-check/re-configure.

## Upgrade procedure

```powershell
wsl --shutdown
wsl --unregister agent-devbox            # system disk gone; data.vhdx untouched
# re-run the installer (imports the new rootfs and re-injects the config)
.\agent-devbox.bat
```

Then verify:

```bash
wsl -d agent-devbox
mount | grep -E 'agent-devbox-data| /home | /root | /workspace '
ls -la ~ /workspace
```

## Verification checklist

| Check | Command | Expected |
|---|---|---|
| Data disk mounted | `mount \| grep agent-devbox-data` | present |
| `/home` from data disk | `findmnt /home` | source under `/mnt/wsl/agent-devbox-data/home` |
| Scheduled Task registered | `schtasks /query /tn agent-devbox-mount-datadisk` | present (RunLevel Highest, trigger AtLogOn) |
| Mount is per-boot | `wsl --shutdown` then reopen; `mount \| grep agent-devbox-data` | re-mounted automatically by the chain |
| Persists across restart | write file → `wsl --shutdown` → `wsl -d agent-devbox` | file present |
| Persists across upgrade | `--unregister` + re-import | file present |

## Automating the re-attach

`wsl --mount` needs admin, and the attach is volatile per boot (`wsl --shutdown`
clears it), so the disk must be re-attached on every boot. Two mechanisms work
together:

- the **logon Scheduled Task** `agent-devbox-mount-datadisk` (RunLevel Highest,
  trigger AtLogOn, action
  `wsl.exe --mount --vhd "<path>" --type ext4 --name agent-devbox-data`) — the
  installer registers it **always** (`-NoTask` opts out); most reliable;
- `wsl-boot.sh` runs a best-effort **fallback chain** on every boot, so a missing
  or failed task does not strand the disk:
  1. if already mounted, stop;
  2. trigger the Scheduled Task via `schtasks.exe /run /tn agent-devbox-mount-datadisk`, then poll;
  3. direct `wsl.exe --mount --vhd <path> --type ext4 --name agent-devbox-data`
     (the explicit `--type ext4` works around whole-disk ext4 auto-detection
     failing on some WSL builds), then poll;
  4. `wsl.exe --mount --vhd <path> --bare`, then locate the device by UUID
     (`blkid -U`) and `mount -t ext4` it manually, then poll.

If every step fails, boot enters **MAINTENANCE MODE** (fail closed: nothing is
seeded or started) and the MOTD tells you to run `agent-devbox.bat` yourself.
`wsl-boot.sh` never auto-launches the Windows installer.
