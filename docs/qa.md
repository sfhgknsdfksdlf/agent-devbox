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

For WSL, CI exports the flat rootfs (`docker export`) **per architecture on a
native runner**: the `export` matrix runs `ubuntu-latest` for amd64 and
`ubuntu-24.04-arm` for arm64, asserts the real ELF in `usr/bin/dash`
(`x86-64` / `ARM aarch64`), compresses with **zstd** (fast + small), splits it
into **<2 GiB** parts, and uploads them as a 3-day artifact. The `publish` job
downloads both artifacts (`merge-multiple`), checks that every part number is
contiguous (`part-00..NN`), writes **one `SHA256SUMS`** covering both
architectures, and creates the Release. This project produces each rootfs on its
native runner; `docker export` itself does not execute the image, so a cross-arch
export is technically possible, but the native runner also lets the same arch run
the Docker smoke test. One shared manifest keeps the installer's verification path
identical on both architectures.

The installer streams the parts for the host's native architecture straight into
`wsl --import -`, where WSL2's own bsdtar decompresses zstd, so the happy path
needs no `zstd.exe` on either Windows 11 or Windows 10. Only the last-resort
import tier fetches a pinned `zstd.exe` from the official facebook/zstd release,
and that tier exists on x64 only (ARM64 uses Tier 1 / Tier 2; see the ARM64 Q&A
below).

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

## 为什么 Windows 安装现在只有 `irm | iex` 一个入口？

**一行安装现在就是唯一入口**：

```powershell
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
```

历史要如实说：早期的推荐方式是把远端脚本"下载后直接执行"（网络取回脚本再交给 PowerShell
执行）。这种"取回即执行"的形态会被静态杀软启发式直接判为下载器 —— 火绒（Huorong）就把当时
那条入口报成 `HEUR:TrojanDownloader/PS.NetLoader.av`。当时的应对是加一个 `cmd.exe` 引导器来
去掉高信号特征；现在**已经把那个引导器、`.bat` 启动器和旧的独立导入脚本都删掉**，安装入口
收敛回一行 `irm | iex`（`install.ps1` 再按需从 `main` 取回 `install-agent-devbox.ps1`、
`wsl-ensure.ps1`、`wsl-ensure-downloads.ps1` 和手动挂载辅助脚本）。

**要注意**：一行 `irm | iex` **并没有"绕过"杀软**——它只是把入口收敛成一个。误报风险靠下面
这些**仍然保留**的缓解措施压低，而不是消除：

- **暂存目录**：从 `%TEMP%`（正是杀软会清理的上下文）挪到 `%LOCALAPPDATA%\agent-devbox\`，
  每次运行用独立的随机子目录，成功和失败后都会清理；
- **惰性下载辅助**：`Install-WslUi` / `Get-ZstdExeFromRelease` 这类"下载并执行"的 helper 拆到
  单独的 `wsl-ensure-downloads.ps1`，正常路径（Tier 1 流式导入）根本不加载它；
- **去掉高信号 API**：`wsl-ensure.ps1` 里不再有内联 C#（`Add-Type -TypeDefinition`）、P/Invoke
  （`DllImport`）或裸 `HttpWebRequest`/`GetResponseStream`——磁盘空间改用托管的
  `System.IO.DriveInfo`，远端 zstd 帧头改用 `HttpClient` 的 Range 请求；
- **执行策略**：提权副本用 `-ExecutionPolicy RemoteSigned`（副本由父进程刚写出，不带
  Mark-of-the-Web），而不是更强的 `Bypass` 信号；
- **rootfs 分片用托管 .NET HTTP 下载**：走 Windows 系统代理（WinINET/PAC，和浏览器同一条），
  Range 断点续传，实时显示 `MiB/s`，停滞自动换连接；下载结束**强制校验文件长度 = Release
  资产大小**，短读只续传、绝不保留。

安装行为本身没有变：仍然先检查磁盘空间再下载、仍然三级回退导入。数据盘**不注册任何计划任务**：
安装器只自己附加一次，之后发行版每次启动由 `wsl-boot.sh` 在发行版内部重新 attach 并挂载；
交互式终端的 `/etc/profile.d` 钩子再把同一块盘接进**该会话所在的挂载命名空间**。
安装脚本从 `main` 取，Release 只用于 rootfs 分片和 1Panel 本地应用包。

## 为什么 rootfs 分片用托管 .NET 下载器，而不是外部下载工具？

**正确性靠长度校验，不靠下载工具**。早先有一次把分片下载改写成 `HttpClient`，新实现把
**EOF 当成了"成功"**、保留了被**截断**的分片，结果导入直接坏掉——这是**缺少收尾校验**的 bug，
不是 .NET 的锅。现在的 `Save-Download` 在**关闭文件句柄之后**强制比对：
最终长度必须等于 `-ExpectedBytes`（Release 资产 `size`）；服务器提供总大小时也一并比对
`Content-Range`/`Content-Length`。不符只续传，绝不 `return`。因此“下了一半”不可能再被当成成功。

选托管 .NET 而不是外部工具的理由是**可用性**：外部下载工具不读 Windows 系统代理（含 PAC），
在开了系统代理 VPN 的机器上会直接卡死；而且静默模式下多 GB 下载**没有任何速度反馈**。
`HttpClient` 走 `GetSystemWebProxy()`（与浏览器同一条代理）、支持 Range 续传、每 2 秒打印
`已下载/总量 MiB + MiB/s`，停滞超时则断开重连续传。Windows 脚本里**不再调用任何外部下载工具**
（`tests/powershell/run.ps1` 有静态守卫）。

## 为什么断点续传必须绑定「下载身份」（以及为什么不用 If-Range）

真机事故：上一次安装（`beta-20261018.1958`）在 `part-00` 留下 9 MiB 残片；下一次安装
（`beta-20261019.1512`）分片文件名相同，于是「旧 tag 的前 9 MiB + 新 tag 的其余字节」拼成一个
**长度完全正确、内容却混合**的文件。三级导入因此全败：Tier 1 / Tier 2 返回 `-1`，Tier 3 的
`zstd -d` 退出码 1；而旧代码把 `wsl.exe` / `zstd.exe` 的输出 `| Out-Null` 了，控制台只剩
「zstd 解压失败（1）」。

现在每个分片下载前先看旁车 `<dir>\.agent-devbox-download\<part>.meta`（URL / 强 ETag / 长度 /
SHA256）。没有旁车或对不上就**整块丢弃重下**；Release 提供 `SHA256SUMS` 时，下载完再校验摘要。
失败路径（`trap` / 导入失败）会删掉本次下载的分片和旁车，下一次运行是干净重下。

**为什么不用 `If-Range`**：实测（2026-10-20，GitHub Releases 背后的 Azure 存储）：

| 请求 | 结果 |
|---|---|
| `Range: bytes=0-9` | 206 |
| `Range` + 过期 `If-Range` | **206（被忽略）** |
| `Range` + 过期 `If-Match` | 412 |
| `Range` + 匹配 `If-Match` | 206 |

所以条件续传用 `If-Match` + 强 ETag；412 就从头重下。行业里的对应做法：rustup 的 `.partial`
按**预期 SHA256** 命名（内容寻址，跨版本残片不可能拼上）；Homebrew 的 `.incomplete` 按 URL
哈希分桶 + 下载前校验 Last-Modified/Length + 下载后 SHA256；Chocolatey / Scoop 一律强制校验和，
校验不过整份重下。

**为什么不用 BITS**：BITS 是 Windows 上「大文件 + 系统代理 + 进度条 + 断点」的经典答案
（`microsoft/MSLab`、`ArduPilot`、`dbatools` 都这么用），但它取 WinHTTP 的系统代理、不带内容
校验，PowerShell 7 也不提供 `BitsTransfer` 模块。我们的下载器已实测走通用户的 PAC 代理，再加
一条传输通道只会多一份失败面。进度条是**下载位置的那一行原地刷新**
（`[####----] 45.2%  1,006/1,900 MiB  22.2 MiB/s`，`\r` + `-NoNewline`，每 ~2 秒）；刻意不用
`Write-Progress`——它画在控制台顶部独立区域，而且不进 transcript。输出被重定向（写日志）时
则改为每 ~2 秒打印一行，保证日志里仍有进度记录。

## 为什么两个架构只有一份 `SHA256SUMS`？

因为安装器的校验路径应当与架构无关。两份清单会立刻带来「清单里混入另一架构分片」「arm64
分支忘了换清单」这类只在半边出现的错误；一份清单则让两架构走完全相同的代码：下载前按
`<arch>` 过滤分片，下载后对同一个 `SHA256SUMS` 查摘要，缺项仍然按「清单存在但未覆盖全部
分片」直接报错。CI 侧也简单：`publish` 用 `upload-artifact` / `download-artifact`
（`merge-multiple: true`）把两套分片汇到一个目录，检查 `part-00..NN` 连续后执行一次
`sha256sum rootfs-*-*.tar.zst.part-* > SHA256SUMS`。这个「多平台产物 + 单份校验和」的做法与
GitHub 官方 artifact 组合的用法一致，也避免了发布阶段的架构分支。

## 为什么 ARM64 跳过 Tier 3？

Tier 3 的唯一作用是下载 `zstd.exe` 再把分片解成 `.tar`，而 facebook/zstd 官方发布的是
**win64** 二进制。在 Windows 11 ARM64 上它要么无法执行，要么只能依赖 x64 模拟，等于把
「最后兜底」变成一个新的失败面。ARM64 因此只保留 Tier 1（流式导入）和 Tier 2（`.tar.zst`
文件导入）：WSL2 自带的 bsdtar 本来就能解 zstd，前两级已经覆盖真实场景。

跳过 Tier 3 时**不设置** `ContentSuspect`：内容并未被证明损坏，设置它会让安装器把分片当成
坏文件删掉。分片与旁车保留在安装目录，重跑安装器会先校验 SHA256 再续传。若两级都失败，
错误信息会提示先执行 `wsl --update` 再重装（旧版 WSL 的解压支持可能不足）。

## 主机架构是如何判断的？

顺序是：`PROCESSOR_ARCHITEW6432` → **Machine 作用域**的 `PROCESSOR_ARCHITECTURE`（注册表）→
进程 `PROCESSOR_ARCHITECTURE` → CIM `Win32_Processor.Architecture`（`12` = ARM64，
`9` = x64）。**不能只看进程环境变量**：ARM64 上以 x64 模拟运行的 PowerShell 会报 `AMD64`，
32 位 WOW64 会报 `x86`，但 Machine 值仍是 `ARM64`。所有来源都无法识别时直接 throw
（fail closed），绝不默认 amd64；这段逻辑是纯函数，单元测试覆盖了 WOW64、x64 模拟与未知值，
wsl-ui 的架构判断也复用同一个 helper。

Windows 10 ARM64 在下载前就会因 build < 22000 被拒绝，不承诺支持；支持的组合只有
**Windows 11 ARM64（build 22000+）**、**Windows 11 x64** 和 **Windows 10 x64**。发行版名
不变（`agent-devbox` / `agent-devbox-core`），变化只在资产名。

## Windows 11 ARM64 真机验收

把 `<distro>` 换成 `agent-devbox` 或 `agent-devbox-core`：

```powershell
wsl -d <distro> -u root -e uname -m
# => aarch64

wsl -d <distro> -u root -e 'wget -q -T 5 -O /dev/null http://127.0.0.1:6767/api/health'
# => exit code 0

wsl -d <distro> -u root -e "ps -o user= -C node | sort -u"
# => paseo

wsl -d <distro> -u root -e 'script -qec "echo pty-ok" /dev/null'
# => pty-ok
```

再看一眼开机日志以 `boot complete` 结尾、数据盘已挂载；最后重跑一次安装器，确认数据盘与
paseo 密码都保留，`uname -m` 仍是 `aarch64`。

## 为什么升级镜像不会重设 paseo 密码？

`/etc/agent-devbox.conf` 在**系统盘**上，而升级 = 注销 + 重新导入系统盘，配置文件会跟着没。
所以密码的权威位置放在**数据盘**：`/mnt/<DATA_MNTNAME>/.paseo-password`（stable 为 `devbox-data`，
beta 为 `devbox-data-beta`；mode 600）。数据盘跨升级保留，安装器在 `[7/10]` 按 UUID 把它挂载起来，
先读这个文件；有就直接沿用，没有才询问/生成，生成后再写回数据盘。
`/etc/agent-devbox.conf` 只是运行期配置（paseo-boot 读它）。

**不再读旧系统盘的 conf**（2026-10-21 起）：迁移窗口已过（改动之前的安装都已升级过，数据盘上
都有 `.paseo-password`）。删掉这一步是为了不再为 `cat` 一个文件把旧发行版整机拉起——`[boot]`
会顺带挂载数据盘并启动 paseo，于是升级时多一次「刚起来又被 terminate」的无谓启停。
升级若读不到数据盘密码，安装器会明确警告「本次会按新密码处理」，绝不静默换密码。

同一个思路也去掉了「是否重装 `[Y/n]`」：升级仍是默认动作，但只有在**交互式控制台**里且未指定
`-Yes` / `-KeepExisting` 时才会问一行——**回车 = 覆盖升级**，`n` = 取消（不下载、不注销、不做
任何改动，退出码 0）；输入其它内容只再问一次，第二次仍无法识别就取消。重定向/无人值守时不会
卡在提问上，直接升级。数据盘（`/home`、`/root`、`/workspace`）与 paseo 密码保留。

## 为什么新开的 WSL 终端里 /root 又回到系统盘？

**因为 WSL 每个发行版只有两个挂载命名空间（提升 / 非提升各一个）。** 普通（非提升）会话共用一个
命名空间，它是**首次出现该级别会话时**从当时状态快照（`unshare`）出来的，可能早于/没有 boot 的挂载；
`[boot]` / PID 1（dockerd、paseo）则在另一个命名空间里（启动发行版的那个提升级别，通常是提升级别，
因为安装器启动它）。所以 `wsl-boot.sh` 明明已经把数据盘挂好并 bind 了 `/home` `/root` `/workspace`，
普通终端里的 `/root` 却仍是系统盘。

**补丁是 `/etc/profile.d` 的登录钩子。** 第一次以交互式 root 登录时，它调用
`/usr/local/bin/wsl-session-mount.sh`，在当前会话自己的命名空间里把数据盘以读写方式重新 mount，
再 bind 三个目录；成功后打印一次 `已把持久数据盘接入当前会话：/home /root /workspace`。它是**幂等**
的：第二个终端发现挂载已在位就直接跳过（零 mount 调用）；提升会话本来就在 PID 1 命名空间里，也直接跳过。

**为什么不挂到 `/mnt/wsl`？** `/mnt/wsl` 是**跨发行版共享**的，把数据盘挂到那里会让同一台机器上其它
发行版也看到这块盘，直接破坏通道隔离（stable / beta 的盘不能互相可见）。所以挂载点保持在
`/mnt/<DATA_MNTNAME>`（`/mnt/devbox-data` / `/mnt/devbox-data-beta`），并且钩子运行前会检查父目录的
传播属性，遇到 `shared` 就拒绝挂载。

**Docker 模式**：镜像是同一个，`IS_DOCKER=true` 时钩子和 helper 都直接返回，**不执行任何 mount**。

**非交互命令**（`wsl -d $Distro -e ...`、`bash -lc` 探针、桌面版 CLI 探测）不会经过登录钩子，所以在
第一次交互登录之前它们看到的仍是系统盘；需要数据盘的脚本请先手动开一次终端。

**维护模式 / 数据盘未附加**：钩子只告警（提示用安装目录的 `mount-datadisk.cmd` 修复），不阻塞登录、
不 attach、不格式化。它全程不调用任何 Windows interop。

## OpenCode 桌面版添加 WSL 服务器提示「未安装 OpenCode」？

根因是从桌面版自己的代码里查出来的（解包 `app.asar`，`out/main/index.js` 的
`resolveWslOpencode()`），不是猜的。桌面版的 WSL 集成只用**一条命令**找 CLI，**完全不查 PATH**：

```sh
sh -lc 'if [ -x "$HOME/.opencode/bin/opencode" ]; then printf "%s\n" "$HOME/.opencode/bin/opencode"; fi'
```

找到之后它就用这个绝对路径执行
`opencode --print-logs --log-level WARN serve --hostname 0.0.0.0 --port <随机端口>`，
用 Basic 认证（用户名固定 `opencode`）轮询 `/api/health`；同时还要求
`opencode --version` 的第一行**与桌面版自身版本完全相同**，发行版里还得有 `bash` 和 `curl`。

本镜像用 npm 装 OpenCode V1（`opencode-ai@^1`），CLI 在 `/usr/local/bin/opencode`。而 WSL 里
`/root`、`/home` 是**数据盘 bind 挂载**，镜像里往 `/root/.opencode` 放东西对**已装机器无效**
（首启 seed 只跑一次，标记是数据盘上的 `.initialized`）。所以探针看不到 CLI，就报未安装。

**已修**（`scripts/wsl-boot.sh` 的 `ensure_opencode_shim`）：

- 每次开机在 bind 校验之后，为 `/root` 和 `/home/*` 建
  `~/.opencode/bin/opencode -> /usr/local/bin/opencode`；幂等：已可执行就跳过（**桌面版自己装的
  真实 CLI 绝不覆盖**），断链替换，目标位置是目录时只告警、不删除；
- `Dockerfile` 的 L11 也在 `/root` 预置同一个链接，所以**新数据盘首启 seed** 就自带；
- 仍然**不装 V2**（`@opencode/cli` 会抢 `opencode` 这个 bin），也不需要桌面版再跑它自带的安装器。

实测（真机数据盘 + 桌面版同样的命令）：链接建好后探针输出
`/root/.opencode/bin/opencode`；`opencode --version` 第一行 `1.19.3`，与桌面版 `1.19.3` 相同；
用完全相同的参数起 sidecar，`/api/health` 返回 **200**（不带认证 401）。探测、版本校验、
sidecar 启动三关都过。

**已装机器不用等新镜像**，在 PowerShell 里立刻补（然后重启桌面版，它只在启动时重新探测）：

```powershell
wsl -d agent-devbox-core -u root -e sh -c "mkdir -p /root/.opencode/bin && ln -sfn /usr/local/bin/opencode /root/.opencode/bin/opencode"
```

一个已知的「时间炸弹」：镜像的 `opencode-ai@^1` 会随 CI 自动升级，而桌面版版本是固定的，
只有两者版本**完全相等**才算匹配。镜像 CLI 升到新版本后，探测仍然通过，但版本校验会不一致
（桌面版会提示更新/尝试它自己的 `curl opencode.ai/install`，那会覆盖我们的链接并在数据盘上多占
约 180MB）。要么升级镜像后同步升级桌面版，要么保持两者同一个 1.x。

> 桌面版只探测 **opencode** 这一个 CLI。其它桌面 App（Claude Desktop 的 WSL 会话、Paseo Desktop、
> VS Code Remote-WSL 等）各自认什么、有没有固定路径要求、装错位置会怎样，见
> **[desktop-cli-detection.md](desktop-cli-detection.md)**；一条命令自查：
> `desktop-cli-check.sh --home /root --also-home /home/paseo`。
