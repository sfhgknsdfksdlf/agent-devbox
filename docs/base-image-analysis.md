# Base image analysis — Debian 12 vs Debian 13

## Decision

Base is **`node:22-trixie-slim`** = **Debian 13 (trixie)** + **Node 22.x**, built
from scratch. We do **not** use the official `ghcr.io/getpaseo/paseo` image.

## Why we can self-build (paseo has no proprietary magic)

The official paseo image only: installs the daemon + CLI, serves the bundled web
UI (which ships *inside* the daemon npm package), listens on `0.0.0.0:6767`, and
runs the daemon as a non-root `paseo` user with an entrypoint that seeds mounted
volumes. Everything it does is reproducible from `npm i -g @getpaseo/cli`. We
recreate: `tini` (PID 1), `gosu` (drop to `paseo`), the `paseo` user (uid/gid
1000), the seed step, the healthcheck, and `EXPOSE 6767`.

## Debian 12 (bookworm) vs Debian 13 (trixie)

| | Debian 12 | Debian 13 |
|---|---|---|
| glibc | 2.36 | 2.41 |
| wrangler/workerd need | glibc >= 2.35 (OK) | OK |
| packages | older | newer |
| Node 22 image | `node:22-bookworm-slim` | `node:22-trixie-slim` |

Both satisfy `wrangler`'s glibc requirement. trixie was chosen for currency and
a longer support window.

## Watch item

`node-pty` (a dependency pulled by the paseo server) may need a native build on
some arch/Node-ABI combinations. The image already installs `build-essential` +
`python3` before the paseo install, so a source build can succeed. CI checks that a
PTY works end-to-end (`script -qec ...`), and node-pty is bundled with the paseo
server inside the image.

## Why not Debian 14?

Debian 14 ("forky") is still *testing*; unsuitable as a production base.
