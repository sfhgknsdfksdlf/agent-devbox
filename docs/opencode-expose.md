# Connecting OpenCode (server) to a remote daemon

OpenCode's CLI can run a headless HTTP server:

```bash
opencode serve --hostname 0.0.0.0 --port 4096
```

Defaults: `--port 4096`, `--hostname 127.0.0.1`. Expose it to reach it from a
Windows desktop OpenCode or another machine.

## Docker (VPS)

The compose file publishes **only 6767**. To also expose the OpenCode server:

```yaml
ports:
  - "6767:6767"
  - "4096:4096"
```

Then run inside the container (as the `paseo` user):

```bash
docker exec -it -u paseo agent-devbox \
  opencode serve --hostname 0.0.0.0 --port 4096
```

Windows desktop OpenCode connects to `http://<vps-host>:4096`.

> Prefer not to expose 4096 publicly. Use an SSH tunnel:
> `ssh -L 4096:127.0.0.1:4096 user@vps` and connect to `http://localhost:4096`.

## WSL2

WSL2 forwards `localhost` to Windows automatically, so:

```bash
opencode serve --hostname 0.0.0.0 --port 4096
```

is reachable from Windows at `http://localhost:4096` without any port publishing.

To reach it from a **phone** on the LAN, expose it from Windows with a portproxy:

```powershell
# admin PowerShell; <WSL-IP> from `wsl hostname -I`
netsh interface portproxy add v4tov4 listenport=4096 listenaddress=0.0.0.0 `
  connectport=4096 connectaddress=<WSL-IP>
New-NetFirewallRule -DisplayName "agent-devbox 4096" -Direction Inbound -LocalPort 4096 -Protocol TCP -Action Allow
```

Or enable WSL2 mirrored networking in `%UserProfile%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

so the distro shares the Windows network stack (no portproxy needed).
