# Docker (VPS) installation

The image is built in CI and published to `ghcr.io/sfhgknsdfksdlf/agent-devbox`
(multi-agent, default) and `.../agent-devbox-core` (lean).

## Quickstart

```bash
cp .env.example .env      # then set PASEO_PASSWORD (required)
docker compose up -d
docker compose logs -f agent-devbox
```

Open `http://<host>:6767` — that is the bundled paseo Web UI.

## Volumes

| Host | Container | Holds |
|---|---|---|
| `${DATA_DIR}/home` | `/home/paseo` | paseo state, agent config + credentials |
| `${DATA_DIR}/project` | `/workspace` | your code |

Updating the image never touches these directories; the entrypoint only seeds
**missing** config, so your settings survive upgrades.

## Ports

Only **6767** is published, and compose maps `6767:6767`. `PASEO_LISTEN` sets
the daemon's bind address (default `0.0.0.0:6767`; IPv6 uses the bracketed form
`[::1]:6767`), and `PASEO_WEB_UI_ENABLED` (`true` / `false`) turns the bundled
Web UI on or off. If you change the internal listen port, update the compose
mapping to match (for example `7777:7777`). To also expose the OpenCode server,
see `opencode-expose.md`.

## Upgrade

```bash
docker compose pull
docker compose up -d
```

## Non-root behavior

The daemon runs as the non-root `paseo` user (uid/gid 1000). Make sure the host
directories are writable by uid 1000:

```bash
sudo chown -R 1000:1000 "${DATA_DIR}"
```

## Health

`GET /api/health` returns 200 once the daemon is up. The image ships a
`HEALTHCHECK`; the optional `autoheal` sidecar restarts the container if the
check fails.
