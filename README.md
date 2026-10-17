# agent-devbox

A three-in-one AI development & testing environment, shipped as **one OCI image
that runs two ways**:

| Mode | How | Persistence |
|---|---|---|
| **Docker** (VPS / server) | `docker compose up -d`, folders bind-mounted | host folders |
| **WSL2** (Windows) | image imported as a WSL distro | a dedicated VHDX data disk |

It bundles **paseo** (daemon + bundled Web UI) · **OpenCode** (latest V1) ·
**omo** (`oh-my-openagent`) · **Cloudflare Workers** tooling · Go/**Wails3** ·
Python/**uv** · Node/**Bun** · Playwright/Chromium · debuggers.

Two images are published:

| Image | What |
|---|---|
| `ghcr.io/sfhgknsdfksdlf/agent-devbox` | **default** — the above **plus** Claude Code, Codex, Gemini, Pi, DeepSeek Harness, Grok Build, zcode, Aider, Crush, Qwen Code, GitHub Copilot CLI |
| `ghcr.io/sfhgknsdfksdlf/agent-devbox-core` | lean base (no extra agent CLIs) |

Tags: `YYYYMMDD.HHMM` (e.g. `20261017.2205`) and `latest`.

## Quickstart — Docker

```bash
cp .env.example .env      # set PASEO_PASSWORD (required)
docker compose up -d
# open http://localhost:6767
```

## Quickstart — WSL

1. Double-click **`agent-devbox.bat`** (default, multi-agent) or
   **`agent-devbox-core.bat`** (lean). Accept the one UAC prompt.
2. `wsl -d agent-devbox`

The installer imports the distro, creates a 32 GB dynamic VHDX data disk,
initializes it, wires it into the boot, and (optionally) registers a logon task
to re-attach it. Re-running it is safe.

See **[docs/installation-wsl.md](docs/installation-wsl.md)** and
**[docs/wsl-persistence.md](docs/wsl-persistence.md)**.

## Runs as

- Interactive shell user: **root**.
- paseo daemon: the non-root **`paseo`** user (uid/gid 1000).
- `PASEO_PASSWORD` is **required** — the daemon refuses to listen without it.

## Ports

- **6767** — paseo daemon + Web UI (the only port published in Docker).
- **4096** — `opencode serve` (default `127.0.0.1`), see
  [docs/opencode-expose.md](docs/opencode-expose.md).

## Building

Images are built **only in GitHub Actions** (never locally):

- every 3 days (`cron "23 3 */3 * *"`, a quiet UTC window, off the top of the
  hour) plus manual dispatch and pushes to `main`;
- pushes build **amd64 only**; scheduled/dispatched builds also build **arm64**
  (natively on GitHub's free ARM runners — no emulation);
- a scheduled run is skipped when no tracked upstream version changed
  (`versions.json` + a diff gate);
- a candidate tag is smoke-tested, then `latest` is promoted;
- a flat WSL rootfs is packaged with zstd and split into <2 GiB parts per Release.

> Note: GitHub auto-disables `on.schedule` workflows in a public repo after 60
> days without activity — the `keepalive` workflow prevents that.

## Repository layout

```
Dockerfile              # core image
Dockerfile.agents       # default multi-agent image (FROM core)
docker-compose.yml      # pull-only (Docker mode)
scripts/                # entrypoints, boot, seeding, data-disk init
config/                 # wsl.conf, profile.d
windows/                # one-click installer (.ps1) + launchers (.bat) + import script
.github/workflows/      # build.yml, keepalive.yml
docs/                   # inventory, base-image, QA, installation, persistence
tests/                  # bats suite
```

## Documentation

- [Software inventory & ecosystems](docs/software-inventory.md)
- [Base image analysis](docs/base-image-analysis.md)
- [Extra agent CLIs & companions](docs/agents-companions.md)
- [Q&A / rationale](docs/qa.md)
- [Docker install](docs/installation-docker.md)
- [WSL install](docs/installation-wsl.md)
- [WSL persistence](docs/wsl-persistence.md)
- [Exposing OpenCode](docs/opencode-expose.md)

## License

MIT — see [LICENSE](LICENSE).
