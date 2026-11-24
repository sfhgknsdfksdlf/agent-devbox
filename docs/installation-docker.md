# Docker (VPS) installation

The image is built in CI and published to `ghcr.io/sfhgknsdfksdlf/agent-devbox`
(multi-agent, default) and `.../agent-devbox-core` (lean).

## Quickstart

```bash
cp .env.example .env      # set PASEO_PASSWORD and DATA_DIR (both required)
DATA_DIR=/srv/agent-devbox   # absolute path; use the same value in .env
export DATA_DIR
mkdir -p "$DATA_DIR"/{home,root,project}
docker compose up -d
docker compose logs -f agent-devbox
```

`DATA_DIR` must be an absolute path. There is no `./data` fallback and compose
does not create it: every bind uses `create_host_path: false`, so a missing
subdirectory is a hard error before the container starts.

Open `http://<host>:6767`; that is the bundled paseo Web UI.

## Volumes

Docker mounts the whole home tree from one host directory, plus a read-only copy
of it as the identity baseline:

| Host | Container | Mode | Holds |
|---|---|---|---|
| `${DATA_DIR}/home` | `/home` | rw | paseo home (`/home/paseo`) and user config/credentials |
| `${DATA_DIR}/root` | `/root` | rw | root's shell home, agent config, caches |
| `${DATA_DIR}/project` | `/workspace` | rw | your code |
| `${DATA_DIR}` | `/run/agent-devbox/data` | ro | baseline used by the preflight only |

`/home`, `/root` and `/workspace` are the only persistent targets. Updating the
image never touches them; the entrypoint seeds **missing** files only, so your
settings survive upgrades.

### Fail-closed preflight

Before any seed, `chown` or service start, `docker-data-preflight.sh` proves each
bind is real:

1. `/run/agent-devbox/data` exists and is a mountpoint;
2. `stat -c '%d:%i'` for `/home`, `/root` and `/workspace` equals the same value
   as `/run/agent-devbox/data/{home,root,project}` respectively.

A missing or mismatched bind is FATAL. The container refuses to start rather than
write into its ephemeral layer and silently lose data.

### First run

Only after the preflight passes does an empty tree get initialized:

- `/home/paseo` created/owned `1000:1000` (the paseo daemon's home);
- `/root` owned `0:0`, mode `0700` (never weakened);
- `/workspace` created if absent;
- missing skeleton files seeded from `/etc/skel` and `/opt/agent-seed` (existing
  files are never overwritten);
- the desktop CLI probe link `~/.opencode/bin/opencode` recreated for `/root` and
  the paseo home.

Ownership is per-directory only; there is no recursive `chown`.

### Why the rest is not mounted

`/opt`, `/usr/local`, `/ms-playwright` and `/var/lib/docker` stay inside the
image (or the WSL system disk). They are tool/browser/engine state, not user
data: mounting host copies over them would shadow image updates, break the "one
immutable image" contract, and in the Docker case leak engine state between
instances. WSL keeps the same three data targets (`/home`, `/root`,
`/workspace`) from the VHDX and the same `stat %d:%i` semantics in the boot
namespace.

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

## Ownership

The daemon runs as the non-root `paseo` user (uid/gid 1000). You do not need to
match ownership on the host: the preflight sets exactly `/home/paseo` to
`1000:1000` and `/root` to `0:0` (mode `0700`), one directory at a time. Do not
recursively `chown` all of `${DATA_DIR}` to `1000:1000`; that would give root's
home and your project to the daemon user and weaken `/root`.

## Health

`GET /api/health` returns 200 once the daemon is up. The image ships a
`HEALTHCHECK`; the optional `autoheal` sidecar restarts the container if the
check fails.
