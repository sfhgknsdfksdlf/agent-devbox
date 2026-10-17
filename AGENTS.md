# PROJECT KNOWLEDGE BASE

**Generated:** 2026-10-17
**Commit:** 712d017
**Branch:** main

## OVERVIEW
One OCI image that is an AI dev/test environment (paseo daemon + web UI, OpenCode V1, omo, toolchains), runnable two ways: Docker (bind-mounted) and WSL2 (persistent VHDX data disk). There is NO application source code — this repo IS Docker/CI/Bash/PowerShell config.

## STRUCTURE
```
agent-devbox/
├── Dockerfile            # core image (Debian 13 + node 22)
├── Dockerfile.agents      # default multi-agent image (FROM core)
├── docker-compose.yml     # pull-only (Docker mode)
├── versions.json          # upstream-version manifest for the CI diff-gate
├── scripts/               # runtime boot logic        (see scripts/AGENTS.md)
├── windows/               # WSL installer + launchers (see windows/AGENTS.md)
├── config/                # wsl.conf + profile.d (login-shell env)
├── .github/workflows/     # build.yml (build+smoke+publish), keepalive.yml, bump-pinned.yml
├── tests/                 # bats suite (run via tests/run.sh)
└── docs/                  # user-facing guides (not agent conventions)
```

## KEY CONTRACTS (no LSP symbols — this is a config repo; these are the interfaces)
| Contract | Where | Rule |
|---|---|---|
| Mode switch | Dockerfile `ENV IS_DOCKER=true`; docker-entrypoint.sh:12 | `docker export` strips ENV, so the WSL rootfs has it unset → runs wsl-boot.sh |
| Daemon identity | scripts/paseo-boot.sh | interactive user = root; daemon = non-root `paseo` (uid/gid 1000) |
| Password gate | scripts/paseo-boot.sh:17 | refuse to listen unless `PASEO_PASSWORD` is set |
| Data disk safety | scripts/datadisk-init.sh + wsl-boot.sh | `mkfs` ONLY in datadisk-init (installer-called); boot never formats; fail-closed |
| Persistence | scripts/wsl-boot.sh:89-91 | `/home`, `/root`, `/workspace` all bind-mounted from the VHDX |
| OpenCode version | Dockerfile:174 | `opencode-ai@^1` (V1) ONLY; never `@opencode/cli` (V2, shares the bin) |
| omo install | Dockerfile:185 | must use `bunx` (npx is broken in Docker) |
| Release packaging | build.yml `publish` | zstd + <2GiB parts; the installer reassembles + unpacks (zstd.exe fetched from the official project) |

## WHERE TO LOOK
| Task | Location |
|---|---|
| Change installed tools / versions | Dockerfile, Dockerfile.agents, versions.json |
| Change boot / daemon behavior | scripts/paseo-boot.sh, scripts/wsl-boot.sh |
| Windows install flow | windows/install-agent-devbox.ps1 |
| CI build / smoke / publish | .github/workflows/build.yml |
| Ports / exposing OpenCode | docs/opencode-expose.md |

## CONVENTIONS
- Shell: `set -euo pipefail`; must pass **shellcheck 0.9.0** (CI's version) AND actionlint's embedded shellcheck — avoid `A && B || C` (SC2015).
- PowerShell: `$ErrorActionPreference='Stop'`; CI AST-parses every `windows/*.ps1`. Never build `cmd` command strings — use native .NET/PowerShell.
- Dockerfile RUN steps are section-bannered (L1..L14); keep that style.
- Auto-latest upstreams are tracked in `versions.json` (the schedule refreshes them with `no-cache`, then records the resolved versions back with a `[skip actions]` commit). Pinned build ARGs are only `PLAYWRIGHT_VERSION` and `GO_VERSION` (bump them in the Dockerfile).
- Pre-commit gate: `bash tests/run.sh`, shellcheck 0.9.0, `pwsh` AST parse, `docker compose config -q`, actionlint.

## ANTI-PATTERNS (THIS PROJECT)
- NEVER set `HOME` globally in the image (the WSL root shell must keep `HOME=/root`; the daemon's HOME is set inside paseo-boot only).
- NEVER install `@opencode/cli` (V2 clobbers the V1 `opencode` bin).
- NEVER format a disk anywhere except `scripts/datadisk-init.sh` (installer-invoked, brand-new disk only).
- NEVER add the data disk to `/etc/fstab` (mounts are explicit binds in wsl-boot).
- NEVER start the daemon without a verified data disk (fail closed → MAINTENANCE MODE).
- NEVER commit `.env`, `data/`, or rootfs archives (`*.tar.gz`, `*.tar.zst`, `*.zst`).
- NEVER build or compile locally — it is slow and leaves a lot of junk on the machine. CI (`.github/workflows/build.yml`) is the ONLY builder, and it runs for every branch. Do not run `docker build`.

## COMMANDS
```bash
# tests + static (CI-equivalent)
bash tests/run.sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.9.0 scripts/agent-env.sh scripts/datadisk-init.sh scripts/docker-entrypoint.sh scripts/paseo-boot.sh scripts/seed-agent-config.sh scripts/wsl-boot.sh tests/run.sh
pwsh -NoProfile -Command "Get-ChildItem windows -Filter *.ps1 | %{ [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName,[ref]\$null,[ref]\$e) }"
PASEO_PASSWORD=x docker compose config -q
docker run --rm -v "$PWD:/r" -w /r rhysd/actionlint:latest

# Builds/compiles are FORBIDDEN on your machine (slow + leaves junk). CI builds every branch.
```

## NOTES
- paseo: `paseo daemon run` + env `PASEO_LISTEN` / `PASEO_WEB_UI_ENABLED` / `PASEO_PASSWORD` / `PASEO_HOME`; `/api/health` is unauthenticated.
- uid 1000 is pre-owned by `node` in the base image → `userdel -r node` before `useradd paseo`.
- aider-chat requires Python <3.13 → installed via `uv tool --python 3.12` (system Python is 3.13).
- CI builds **both** amd64 and arm64 on every run, natively (`ubuntu-latest` + `ubuntu-24.04-arm`), then merges a multi-arch manifest.
- WSL/Windows paths are NOT executable on Linux CI/host — they are covered by static lint + PowerShell AST only.
- Artifacts: container images → **ghcr.io**; WSL rootfs parts → **GitHub Releases** (not ghcr). `zstd.exe` (Win10 has no zstd) is fetched by the installer from the official facebook/zstd release (pinned). Only schedule/dispatch promote `latest` + cut a stable Release; pushes publish test tags (`main` = `<YYYYMMDD.HHMM>`, other branches = `beta`) **and** a moving `beta` prerelease carrying the WSL rootfs + Windows zip + 1Panel zip (testable via `-ReleaseTag beta`), and never touch `latest`.
- **Pinned upstreams (`PLAYWRIGHT_VERSION`, `GO_VERSION`) move on a slower, separate cadence.** They are pinned on purpose (Playwright = npm client + Chromium + system deps; Go = system toolchain, no stable "latest" URL) and are NOT in the `versions.json` diff-gate, so the every-3-day build never touches them. `bump-pinned.yml` (cron: every 6 months, 1st of Jan/Jul) upgrades them to the latest upstream and dispatches a rebuild. Security releases are NOT covered by that cadence — bump those manually as soon as they land.
