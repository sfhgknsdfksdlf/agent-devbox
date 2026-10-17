# WSL installation (Windows)

Two ways to get the image into WSL. Both need **no Docker on Windows**.

## Path A — one-click script (fully automatic, recommended)

Double-click one of:

- `agent-devbox.bat` — the **default, multi-agent** image
- `agent-devbox-core.bat` — the lean base image

The script (running elevated, one UAC prompt) will:

1. download + reassemble the released rootfs and `wsl --import` the distro
   `agent-devbox`;
2. create a 32 GB dynamic `data.vhdx` in the install dir and initialize it;
3. write the boot config (VHDX path + UUID + password);
4. optionally register a logon Scheduled Task to re-attach the disk;
5. restart the distro.

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

`windows/import-distro.ps1` only downloads + reassembles the released rootfs and
runs `wsl --import`. It does not set up the data disk.

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
