# Q&A — decisions and rationale

## Versions & update policy

| Thing | Policy |
|---|---|
| OpenCode | **latest V1** via `opencode-ai@^1` (npm resolves the max 1.x). V2 (`@opencode/cli`) is a *separate package* and is **never installed** (it would clobber the `opencode` bin). |
| omo | `oh-my-openagent@latest` (plugin entry `"oh-my-openagent@latest"`). |
| paseo | `@getpaseo/cli` latest. |
| wrangler | latest 4.x. |
| Fixed | Playwright, Go (pinned ARGs). |

A rebuild picks up new versions; `versions.json` + the CI diff-gate record what
was resolved and skip a scheduled build when nothing upstream changed.

## "Will frequent auto-builds get me banned?"

No. There is no penalty for scheduled builds. Two real caveats:

1. GitHub **disables `on.schedule` workflows in a public repo after 60 days
   without repository activity**. The `keepalive` workflow makes an empty commit
   every 20 days to reset the timer.
2. Actions minutes: **public repos are free**; GHCR public images are free to
   pull. (Private repos get 2000 Actions minutes/month.)

Scheduled runs share the global runner queue; scheduled times are best-effort.
We schedule at `23 3 */3 * *` (quiet UTC window, off the top of the hour) and
use a `concurrency` group.

## Compression / image size

Docker/OCI layers are **already gzip-compressed** in the registry, so "compress
before upload" is a no-op for pull size. Real levers used here: cache cleaning in
the same `RUN` layer, `--no-install-recommends`, `provenance:false`,
`sbom:false`, and buildx `type=gha` cache. The 10+ GB figure is the *unpacked*
size; what users pull is compressed.

For WSL, CI exports a flat rootfs (`docker export`), compresses it with **zstd**
(fast + small), and splits it into **<2 GiB** parts so it fits GitHub Release's
per-asset limit. Windows 10 has no built-in zstd, so the installer fetches a
pinned `zstd.exe` from the official facebook/zstd release and uses it to unpack.

## base / rootfs formats

- WSL `--import` needs a **flat filesystem tar**, so CI uses `docker export`
  (not `docker save`, which produces a layered archive WSL cannot import).
- `docker export` does **not** carry image config (ENV), which is exactly why
  `IS_DOCKER=true` being baked into the image is a clean Docker-vs-WSL switch.

## wsl-ui

[octasoft-ltd/wsl-ui](https://github.com/octasoft-ltd/wsl-ui) is a Windows GUI
(via Tauri) that can install a distro **from a Docker/Podman image** using its
own bundled OCI implementation — **no Docker required**. You can point it at
`ghcr.io/sfhgknsdfksdlf/agent-devbox:latest`. The scripted path (Release rootfs +
`wsl --import`) is provided as the fully automatic alternative.

## Performance

- **WSL distro imported from an OCI image ≈ a Store distro**: both are an
  `ext4.vhdx` on the same WSL2 kernel/VM. No meaningful difference.
- **Docker vs WSL**: same kernel; Docker adds container isolation/networking, so
  the difference is negligible for development.

## Ports

- **paseo** daemon + Web UI: **6767**. In Docker (VPS) this is the only published
  port. In WSL, Windows reaches `localhost:6767`; a phone needs a portproxy or
  mirrored networking.
- **OpenCode server**: `opencode serve` defaults to `127.0.0.1:4096`. See
  `opencode-expose.md`.

## User model

The interactive shell user is **root** (as requested). The paseo **daemon runs as
the non-root `paseo` user** (uid/gid 1000), mirroring the official image — a
network-listening service should not run as root. Only services need a dedicated
user; the other tools are CLIs that run as whoever invokes them.

## Password

`PASEO_PASSWORD` is **required**. The launcher refuses to start without it. The
Windows installer generates one (or prompts) and stores it in the distro's
`/etc/agent-devbox.conf` (0600).
