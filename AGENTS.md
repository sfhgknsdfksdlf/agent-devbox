# PROJECT KNOWLEDGE BASE

**Updated:** 2026-10-22 · **Branch:** main · Deep Windows contracts: `windows/AGENTS.md`; shell boot: `scripts/AGENTS.md`.

## OVERVIEW
One OCI image = an AI dev/test environment (paseo daemon + web UI, OpenCode V1, omo, toolchains), used two ways: Docker (bind mounts) or WSL2 (imported rootfs + an independent VHDX data disk). There is NO application source — this repo is Dockerfile / Bash / PowerShell / CI config.

## STRUCTURE
```
Dockerfile / Dockerfile.agents   # core image (Debian 13 + node 22) / default multi-agent layer
docker-compose.yml               # pull-only (Docker mode)
versions.json                    # upstream-version manifest for the CI diff-gate
scripts/                         # runtime boot logic
windows/                         # WSL installer (PowerShell) + manual data-disk helpers
config/                          # wsl.conf + profile.d
.github/workflows/               # build.yml (build+smoke+publish), keepalive.yml, bump-pinned.yml
tests/                           # bats (tests/run.sh) + PowerShell (tests/powershell/)
docs/                            # user-facing guides
```

## CONTRACTS
| Contract | Rule |
|---|---|
| Mode switch | `Dockerfile` sets `ENV IS_DOCKER=true`; `docker export` strips ENV, so the WSL rootfs runs `scripts/wsl-boot.sh` instead. |
| Daemon | interactive user = `root`; daemon = non-root `paseo` (uid/gid 1000); refuses to listen without `PASEO_PASSWORD`. |
| Data disk | `mkfs` ONLY in `scripts/datadisk-init.sh` (installer-invoked, brand-new disk). Boot never formats; any failure → MAINTENANCE MODE, fail closed. Never `/etc/fstab`. `/home`, `/root`, `/workspace` bind-mounted from the VHDX, verified by `stat %d:%i` (not `findmnt`). |
| OpenCode / omo | `opencode-ai@^1` only (never `@opencode/cli` — V2 clobbers the bin); omo installs via `bunx` (npx is broken in the image). |
| Desktop CLI | The desktop app resolves a WSL CLI ONLY at `$HOME/.opencode/bin/opencode` (no PATH lookup), needs `opencode --version` == app version, then runs `serve`. Boot recreates that link per home on the data disk; `scripts/desktop-cli-check.sh` is the read-only self-check. A failed probe is cached for the app's whole session → restart it fully (tray too). |
| Release channels | schedule/dispatch → dated image tag + stable Release `build-<ts>` + promote `latest`; push to main → image `<ts>` + prerelease `beta-<ts>`; any other branch → `beta-<ts>`. Every push moves `:beta` and prunes older `beta-*` (newest survives). Push NEVER promotes `latest`. |
| Artifacts | images → ghcr.io; WSL rootfs parts per arch (`rootfs-<variant>-<arch>.tar.zst.part-*`, zstd, <2GiB each, produced by the native `export` matrix → artifacts → `publish`) with ONE merged `SHA256SUMS` covering both arches, + 1Panel zip → GitHub Releases; the Windows entry is ONLY the raw `main` one-liner (`irm .../windows/install.ps1 \| iex`). |
| Windows install | `install.ps1` fetches the siblings from the SAME `-Ref` (raw source tree, NOT the Release), verifies `windows/SHA256SUMS` before dot-sourcing (missing manifest → `-AllowUnverifiedScripts`; partial/mismatch → fatal), then runs `install-agent-devbox.ps1`. `$Ref` = `-Ref` > `$env:AGENT_DEVBOX_REF` > prompt > `main`; `irm\|iex` cannot see the URL branch (branch installs must pass `-Ref`/env). `$Channel` = `beta` iff `$Ref -ne 'main'` else `stable`, passed as `Channel` in the splat; the installer's `-Channel` (`stable\|beta`, default `stable`) is forwarded in its UAC argv and never receives `-Ref`; `-ReleaseTag b\|beta` = newest `beta-*` prerelease (independent of `-Ref`). Names append `-beta` (`agent-devbox[-core][-beta]` / `D:\WSL\...`). Host arch is resolved fail-closed (`PROCESSOR_ARCHITEW6432` → machine-scope registry `PROCESSOR_ARCHITECTURE` → process env → CIM `12`/`9`) and selects `rootfs-*-<arch>`; ARM64 (Windows 11 build 22000+ only) skips Tier 3, and after import, before `datadisk-init.sh`/mkfs, `uname -m` must equal `aarch64` (`x86_64` on amd64), else unregister the new distro, remove only `ext4.vhdx`, keep `data.vhdx` + parts. Rootfs parts go through `Save-Download` (managed `System.Net.Http.HttpClient`: proxy/PAC, Range+`If-Match`, `412` restart, length+SHA256 gate, sidecar identity in `.agent-devbox-download\`). The lazily loaded `wsl-ensure-downloads.ps1` (wsl-ui + Tier-3 zstd) is OPTIONAL in the hash gate. Upgrade also repairs Windows Terminal `--distribution-id` (GUID read from `HKCU\...\Lxss`). |
| WSL data-disk mount | Per-channel+variant distro/dir (`agent-devbox[-core][-beta]`), each with its OWN `data.vhdx` (no shared home/root/workspace); ext4 label == mount name: `devbox-data` (stable) / `devbox-data-beta` (beta, 16 chars = ext4 limit) → `/mnt/<label>`. Conf = 6 keys (`DATA_VHDX`, `DATA_UUID`, `DATA_LABEL`, `PASEO_PASSWORD`, `DATA_MNTNAME`, `DATA_DISTRO`); guest precedence `AGENT_DEVBOX_DATA_LABEL` > conf `DATA_LABEL` > `devbox-data`. `datadisk-init` non-zero = FATAL (never write another channel's UUID/password into this conf), `data.vhdx` kept. Ownership valve: a dir with `data.vhdx`/`ext4.vhdx` belongs to one channel via `<dir>\.agent-devbox-channel` (missing = legacy stable), mismatch throws before the installer's UAC (entry already elevated under `irm\|iex`). Stable+beta coexist (distinct distro/dir/disk/password/WT fragment+GUID); same-channel agents/core disks interchangeable, cross-channel not; `%LOCALAPPDATA%\agent-devbox` staging is shared (per-run dirs/logs), `.wslconfig`/mirrored networking/`wsl --shutdown` stay host-global. Every distro start runs `wsl-boot.sh`, which itself makes ONE bounded `wsl.exe --mount --vhd <path> --bare` call (hard timeout; skipped when the device is already attached) and then mounts it in Linux. Same-channel agents/core share the label; boot resolves the device by UUID first (all devices carrying it) and falls back to the label only when no device carries that UUID, and more than one candidate fails closed instead of picking one (e.g. a copied `data.vhdx` whose original is still attached); same-channel agents/core disks have different UUIDs, so both may stay attached. There is NO Windows scheduled task: the installer only attaches once and unregisters legacy `agent-devbox*-mount-datadisk` entries; the pure-batch install-dir `mount-datadisk.cmd` is the manual repair entry (no UAC). `wsl-boot.sh` must never call `schtasks` / `wsl -d` / `--unmount` (that caused a boot loop). `wsl --terminate` keeps the attach; `wsl --shutdown` detaches ALL mounted disks by design; a Windows restart ALWAYS loses the attach (WSL's re-attach state is a VOLATILE registry key). On failure: MAINTENANCE MODE, banner prints `cmd.exe /c "<InstallDir>\mount-datadisk.cmd"` + `wsl.exe --terminate <distro>` (PowerShell fallback: `<InstallDir>\mount-datadisk.cmd` + `wsl --terminate <distro>`), `boot failed` (never `boot complete`). |
| PS encoding | `install.ps1` UTF-8 **without** BOM (in-memory fetch keeps a BOM as U+FEFF and breaks PS 5.1); other `windows/*.ps1` UTF-8 **with** BOM; `.cmd` ASCII + CRLF. CI ps-lint enforces. |

## WHERE TO LOOK
| Task | Location |
|---|---|
| Tools / versions | `Dockerfile`, `Dockerfile.agents`, `versions.json` |
| Boot / daemon | `scripts/paseo-boot.sh`, `scripts/wsl-boot.sh` |
| Windows install | `windows/install.ps1`, `install-agent-devbox.ps1`, `wsl-ensure*.ps1` |
| CI build / smoke / publish | `.github/workflows/build.yml` |
| Ports / OpenCode exposure | `docs/opencode-expose.md` |

## CONVENTIONS
- Shell: `set -euo pipefail`; must pass shellcheck 0.9.0 AND actionlint's embedded shellcheck — avoid `A && B || C` (SC2015). Exception: `scripts/wsl-boot.sh` omits `-e` (best-effort boot).
- PowerShell: `$ErrorActionPreference='Stop'`; never build `cmd` command strings (use native .NET/PowerShell). CI AST-parses every file, enforces the BOM policy, and runs the entry under the real **5.1** host.
- Host arch: `Get-AgentDevboxHostArch` precedence = `PROCESSOR_ARCHITEW6432` → machine-scope `PROCESSOR_ARCHITECTURE` (registry) → process env → CIM `Win32_Processor.Architecture` (`12`=ARM64, `9`=x64); unknown throws (never assume amd64). **Never trust the process `PROCESSOR_ARCHITECTURE` alone**: x64-emulated PowerShell on ARM64 reports `AMD64`, WOW64 reports `x86`.
- Channel identity table lives ONLY in `Get-AgentDevboxChannelIdentity` (`windows/wsl-ensure.ps1`; 4 rows = agents|core × stable|beta); `install.ps1` keeps a 4-line inline derivation (`wsl-ensure.ps1` is fetched only after the dir prompt). Never hardcode `agent-devbox*` / `devbox-data*` names in `install-agent-devbox.ps1`.
- Dockerfile RUN steps stay section-bannered (L1..L14).
- `versions.json` is the auto-latest diff-gate; only `PLAYWRIGHT_VERSION` and `GO_VERSION` are pinned (bumped by `bump-pinned.yml`, not the 3-day build).
- After ANY `windows/*.ps1` or `*.cmd` edit: `git add windows/` **then** `bash .github/scripts/update-windows-sums.sh` (hashes staged blobs).

## PITFALLS (hard-earned — do NOT repeat)
**火绒 `HEUR:TrojanDownloader/PS.NetLoader`**
- Symptom: `wsl-ensure-downloads.ps1` deleted mid-install → elevated child dies → original window shows only `安装失败（退出码 1）`, no installer log.
- Cause: PS 5.1 `Invoke-WebRequest -OutFile` + running the fetched `.exe` is the malware downloader fingerprint; adding **`-UseBasicParsing`** pushes it over the line. Huorong scores statically AND behaviourally (AMSI + its PSET script engine) — token shuffling does not help.
- Evidence (identical bytes): `0742690` loads fine · `73a1a03` (token in 2 calls) quarantined · next attempt (IWR removed, token left in a **comment**) quarantined again.
- Rules: no such token anywhere in that helper, comments included (`tests/powershell/run.ps1` asserts). `install.ps1` legitimately uses it for sibling downloads — don't copy that into the helper, don't "unify" them. Fix IWR hangs structurally (winget / manual), never by re-adding the flag. Signing the `.ps1` does NOT help.
- Recurrence: preflight `1` (no wsl-ui) still installs; report the FP to `bbs.huorong.cn/forum-44-1.html` / `seclab@huorong.cn` (zip password `infected`).

**PowerShell 5.1 ≠ pwsh 7 (production host is 5.1)**
- `.Content` may be `byte[]` → parses to zero entries. Remote text = `-OutFile` then `[System.IO.File]::ReadAllText`.
- `Join-Path A B C` is PS 7 only → nest two calls.
- Native stderr + `$ErrorActionPreference='Stop'` becomes terminating → use `Invoke-Native`.
- PSCustomObject: assigning a MISSING property throws → `Add-Member -Force` (a WT profile without `commandline` aborted the repair → stale GUID → wsl-ui 打不开终端，`wsl -d` 正常).
- `#Requires` in the in-memory `irm | iex` path is fine, but **pwsh 7 green is not evidence** — only the ps-lint 5.1 run proves it.

**Failure must be self-explaining**: pre-installer failures write `$LogPath.err` and the original window echoes `===== 失败原因 =====`. Never ship an exit-code-only failure (the elevated console is a separate window).

**通道所有权阀**：目录含 `data.vhdx`/`ext4.vhdx` 即属于一个通道（`<dir>\.agent-devbox-channel`，缺失=legacy stable）；beta + `-InstallDir`（原样使用，绝不追加 `-beta`）指向另一通道的盘时，必须在**安装器自己的 UAC / 第一次改盘之前** throw，绝不覆盖对方的 UUID/密码。入口的 `Ensure-Wsl`/`Set-MirroredNetworking` 已先跑：生产资产不会被动，但主机级 `.wslconfig` 可能已被改动。

**WT profile / 数据盘修复入口（实测 2026-10-20）**
- 旧版本会留下 `<distro>-mount-datadisk` 任务，旧式 `--mount --type ext4 --name` 还会把旧盘挂到所有发行版可见的 `/mnt/wsl/<name>` → 现在不再创建任何任务，安装器只按「发行版已不在 `wsl -l`」或「VHDX 不存在」注销这些旧任务。
- **WT profile 用固定 GUID 的 fragment**：镜像 `/etc/wsl-distribution.conf` 设 `[windowsterminal] enabled=false`（否则 WSL 每次 import 按注册表 GUID 生成新 profile，重装即换 GUID）；安装器写 `Fragments\AgentDevbox\<发行版>.json`（固定 GUID + `wsl.exe -d <名字>` + `\\wsl$\<发行版>\root`），并删除 `Fragments\Microsoft.WSL` 里属于本发行版的旧条目。fragment 必须在 `[4/10] import` **之前**写（Modern=1 且生成器关闭时没有自动 profile）。
- 密码只从数据盘 `.paseo-password` 读（`[7/10]`）；不要再为 `cat` 旧 conf 启动旧发行版（`[boot]` 会拉起 paseo，升级白启停一次）。读不到时明确告警，不静默换密码。
- **密码写入必须重挂 + 校验 UUID + 写后回读（实测 2026-10-24）**：读/写两步之间发行版可能重启（写 conf 的那次 `wsl -d` 触发 boot，boot 因 conf 未写而跳过挂载），旧代码只凭 `$dataDiskMounted` 把 `.paseo-password` 写进系统盘 `/mnt/<name>`（rc 0、日志假成功）→ 数据盘没有密码、下次升级换密码。写入命令内先 `mkdir -p`，未挂载则 `mount -t ext4 $(blkid -U)`，`findmnt -rno UUID` 校验，`sync` 后 `cat` 回读；禁止信任陈旧挂载标志。
- `daemon.log` 由 paseo 自己按 10MB×3 轮转（`supervisor-log-config.js`）；`/var/log/paseo-boot.log` 是 `wsl-boot.sh` 的 `>>` 重定向，启动前按 5MiB 滚成 `.1`。
- 升级的 `wsl --unregister` 必须排在「分片下载 + SHA256 校验」之后（放 [2/10] 时下载失败会把旧系统盘一起删掉）；`datadisk-init.sh` 只做 `mkfs`，seed 只在 `wsl-boot.sh`（失败不写 `.initialized`）；清理残留的旧挂载后要顺手 `wsl --unmount` 旧 VHDX；CI 不变量只放 `run.ps1`，build.yml 不再重复 grep（重复副本曾把 ps-lint 判红）。
- **`wsl --mount` 的失败会被 `-EncodedCommand` 吞掉**（PowerShell 退出 0）→ 历史教训：安装器曾以为 attach 成功，重启后 wsl-boot 找不到设备、静默进维护模式。现在 boot 自己发起一次硬超时 attach；手动修复改用纯批处理 `mount-datadisk.cmd`（直接 `wsl.exe --mount --vhd --bare`，3 次重试 + `datadisk-attach.log` + 真实退出码，不再包一层 `-EncodedCommand`），安装器也自己 attach 一次，重启后 `Assert-DataDiskMounted` 只认**本次新增**的 boot 日志（`tail -n +N` 找 `boot complete`，遇 `boot failed` 立即失败），失败即报错并打印修复命令。绝不允许「安装成功但进维护模式」。
- **`wsl -d` 会话看不到 `[boot]` 会话建立的挂载**（2026-10-21 22:05 实测：boot 已「数据盘挂载成功 / boot complete」并起了 paseo，`wsl -d ... findmnt` 连续 45s 全空）→ 挂载校验只能用 boot 日志这类文件证据，不能只用 findmnt。
- **绝不在另一个发行版里直接 `mount` WSL 的 `/dev/sdX`**（2026-10-22 实测事故）：`mount -o ro,noload /dev/sdf`（= core 的 ext4.vhdx）会把 ext4 超级块钉成只读，之后 `wsl -d agent-devbox-core` 报 `无法启动分发。错误代码: 16，失败步骤: 2` / `Wsl/Service/CreateInstance/E_FAIL`；dmesg 证据 `sdf: Can't mount, would change RO state` + `UtilMount:1850 ... failed 16`（errno 16 = EBUSY）。**卸载即恢复**。读镜像内日志只用「`cp` vhdx → `qemu-img check -r all` → `qemu-nbd --read-only` 挂副本」。

**ARM64 / WSL 架构**
- `wsl --import` **不校验架构** → 导入后、`datadisk-init.sh`（mkfs）之前必须跑 `uname -m`；不匹配或 `Exec format error` 就注销新发行版、只删 `ext4.vhdx`，保留 `data.vhdx` 与已下载分片。
- ARM64 绝不下载 `zstd.exe`（只有 win64）；跳过 Tier 3 时不得设 `ContentSuspect`，分片保留供重试；资产名不得写死 `rootfs-$Variant-amd64`。
- 架构检测不可识别即 throw（fail closed）；CI 不变量只在 `run.ps1`，build.yml 不放重复 grep。

## ANTI-PATTERNS
- NEVER set `HOME` globally in the image (root shell needs `HOME=/root`; the daemon's HOME is set in `paseo-boot` only).
- NEVER install `@opencode/cli`; NEVER `docker build` locally — CI is the only builder and it runs for every branch.
- NEVER format a disk outside `scripts/datadisk-init.sh`; NEVER add the data disk to `/etc/fstab`; NEVER start the daemon without a verified data disk.
- NEVER commit `.env`, `data/`, or rootfs archives (`*.tar.gz`, `*.tar.zst`, `*.zst`).
- NEVER add a BOM to `windows/install.ps1` or strip it from the other `windows/*.ps1`; NEVER add a second Windows install entry (no `.cmd`/`.bat` bootstrapper).
- NEVER print `PASEO_PASSWORD` to the console or a log; it lives only in `/etc/agent-devbox.conf`.

## COMMANDS
```bash
# tests + static (CI-equivalent)
bash tests/run.sh
pwsh -NoProfile -File tests/powershell/run.ps1                 # 600 assertions, no deps
pwsh -NoProfile -File tests/powershell/iex-smoke.ps1           # also: powershell -File ... (5.1)
pwsh -NoProfile -Command "Invoke-Pester -Path tests/powershell/install.Tests.ps1 -CI"
pwsh -NoProfile -Command "Get-ChildItem windows -Filter *.ps1 | %{ [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName,[ref]\$null,[ref]\$e) }"
git add windows/ && bash .github/scripts/update-windows-sums.sh  # after ANY windows/*.ps1|*.cmd edit
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.9.0 scripts/*.sh tests/run.sh
docker run --rm -v "$PWD:/r" -w /r rhysd/actionlint:latest
PASEO_PASSWORD=x docker compose config -q
```

## NOTES
- paseo: `paseo daemon run` + `PASEO_LISTEN` / `PASEO_WEB_UI_ENABLED` / `PASEO_PASSWORD` / `PASEO_HOME`; `/api/health` is unauthenticated.
- uid 1000 is pre-owned by `node` → `userdel -r node` before `useradd paseo`. aider-chat needs Python <3.13 (`uv tool --python 3.12`; system Python is 3.13).
- CI builds amd64 + arm64 images natively (`ubuntu-latest`, `ubuntu-24.04-arm`) then merges a multi-arch manifest; `smoke` is the same 2-arch native matrix, and the `export` matrix exports the WSL rootfs per arch (artifacts → `publish`).
- Windows/WSL paths cannot run on the Linux host; real coverage is the `ps-lint` job on `windows-latest` (AST, BOM/`.cmd` policy, `run.ps1`, Pester, 5.1 IEX smoke).
