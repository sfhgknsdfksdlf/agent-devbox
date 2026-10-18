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
per-asset limit. The installer streams those parts straight into `wsl --import -`,
where WSL2's own bsdtar decompresses zstd, so the happy path needs no `zstd.exe` on
either Windows 11 or Windows 10. Only the last-resort import tier fetches a pinned
`zstd.exe` from the official facebook/zstd release.

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

## Why PowerShell, not a Go rewrite?

We **keep PowerShell**. Registering a distro is language-neutral: it bottoms out in
`wslapi.dll` (`WslRegisterDistribution`) or `wsl --import`, which every language
shells out to anyway. The recurring "it opens a new window and shows no output"
complaint is not a PowerShell problem: it is an inherent UAC / ShellExecute
`runas` limitation (the same in any language), and it is solved by the log relay
(the elevated window writes a transcript; the original window waits and echoes
it), not by switching languages. A Go rewrite would add a toolchain and CI to
maintain, would still have to shell out for VHDX creation (`New-VHD` /
`diskpart`), and would still need admin. Prior art:
[yuk7/wsldl](https://github.com/yuk7/wsldl) is Go, but it is a thin in-distro
launcher without the VHDX, Scheduled Task, or ACL work this installer does.

## 为什么不再推荐 PowerShell 一行安装 / 为什么改用 `install.cmd`?

旧的推荐方式是把远端脚本"下载后直接执行"（网络取回脚本再交给 PowerShell 执行）。这种
"取回即执行"的形态会被静态杀软启发式直接判为下载器：火绒（Huorong）就把这条入口报成
`HEUR:TrojanDownloader/PS.NetLoader.av`。于是入口换成 `install.cmd`，行为不变，去掉的是
高信号的静态特征：

- **入口**：`cmd.exe` 引导器 `install.cmd`（或原始网页入口 `install.ps1`）；两者都从
  **项目源码 `main`** 取安装脚本；
- **暂存目录**：从 `%TEMP%`（正是杀软会清理的上下文）挪到 `%LOCALAPPDATA%\agent-devbox\`，
  每次运行用独立的随机子目录，成功和失败后都会清理；
- **共享辅助**：`wsl-ensure.ps1` 里不再有内联 C#（`Add-Type -TypeDefinition`）、P/Invoke
  （`DllImport`）或裸 `HttpWebRequest`/`GetResponseStream`——磁盘空间改用托管的
  `System.IO.DriveInfo`，远端 zstd 帧头改用 `HttpClient` 的 Range 请求；
- **执行策略**：旧的原始网页入口 `install.ps1` 在提权时不再用 `-ExecutionPolicy Bypass`，
  而是 `RemoteSigned`（提权后的副本由父进程刚写出，不带 Mark-of-the-Web，`RemoteSigned`
  已经足够，也更不像恶意样本）。

安装行为本身没有变：仍然先检查磁盘空间再下载、仍然三级回退导入、仍然注册数据盘开机挂载；
`install.cmd`/`install.ps1` 从 `main` 取脚本；rootfs 分片用系统自带 `curl.exe`（`-C -` 续传、
校验 Content-Length，短读即重试）下载，Release 只用于 rootfs 镜像。
