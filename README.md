# agent-devbox

一个"三合一"的 AI 开发 / 测试环境：**同一个镜像，两种用法**。

| 用法 | 怎么用 | 数据存哪 |
|---|---|---|
| **Docker**（服务器 / VPS） | `docker compose up -d`，目录直接挂载 | 服务器上的文件夹 |
| **WSL2**（Windows） | 把镜像导入成一个 WSL 发行版 | 一块独立的数据磁盘（VHDX） |

内置 **paseo**（后台服务 + 自带网页界面）· **OpenCode**（最新 V1）· **omo**（`oh-my-openagent`）·
**Cloudflare Workers** 工具 · Go/**Wails3** · Python/**uv** · Node/**Bun** · Playwright/Chromium · 调试器。

发布两个镜像：

| 镜像 | 内容 |
|---|---|
| `ghcr.io/sfhgknsdfksdlf/agent-devbox` | **默认版** —— 上面的全部，**外加** Claude Code、Codex、Gemini、Pi、DeepSeek Harness、Grok Build、zcode、Aider、Crush、Qwen Code、GitHub Copilot CLI |
| `ghcr.io/sfhgknsdfksdlf/agent-devbox-core` | 精简版（不含额外的 AI 助手） |

标签：`latest`、稳定版日期标签 `YYYYMMDD.HHMM`（例如 `20261017.2205`），以及推送构建的 `beta-YYYYMMDD.HHMM` / `:beta` 别名。

## 快速开始 —— Docker

```bash
cp .env.example .env      # 设置 PASEO_PASSWORD（必填）
docker compose up -d
# 浏览器打开 http://localhost:6767
```

## 快速开始 —— WSL

在 Windows 上打开 PowerShell，运行**唯一的一行安装命令**：

```powershell
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
```

这就是**唯一的安装入口** —— 不用再去 Releases 手动下载 zip，也不用双击 `.bat` 启动器。它会：

- 自动请求一次管理员授权（UAC），自动装好 WSL（可选带上 [wsl-ui](https://github.com/octasoft-ltd/wsl-ui) 图形界面）并建议开启镜像网络；
- 安装脚本（`install-agent-devbox.ps1`、`wsl-ensure.ps1`、`wsl-ensure-downloads.ps1`）从**所选的代码分支/标签（默认 `main`）**取回，只有 rootfs 镜像分片来自 Release；每个脚本都会按同分支的 `windows/SHA256SUMS` 校验（旧版本没有清单时才需要 `-AllowUnverifiedScripts`）；
- 交互运行时询问装哪个镜像（回车＝完整版多助手 `agents`，输入 `c`＝精简版 `core`）和哪个版本（回车＝`latest`，输入 `b`＝最新 `beta`，也可直接输入版本号），最后询问代码分支（回车＝`main`，输入 `?` 列出全部分支；开发测试用）；
- 装完自动清理临时文件。

装好后用**哪个名字取决于你装的变体**：完整版是 `agent-devbox`，精简版是 `agent-devbox-core`。
记不住、或者怕粘贴错，就在 Windows PowerShell 里粘一次下面这段——它自动认出已装的变体并设为默认：

```powershell
$env:WSL_UTF8 = 1
$Distro = (wsl -l -q) | ForEach-Object { ($_ -replace "`0", '').Trim() } |
  Where-Object { $_ -like 'agent-devbox*' } | Select-Object -First 1
if (-not $Distro) { throw '没找到 agent-devbox / agent-devbox-core，请先跑上面那条安装命令' }
wsl --set-default $Distro
"使用发行版：$Distro"
```

之后在**同一个 PowerShell 窗口**里，所有命令都可以直接写 `wsl -d $Distro ...`；不想用变量就显式写
`wsl -d agent-devbox`（agents）或 `wsl -d agent-devbox-core`（core）。

安装脚本会自动：**下载前先检查目标磁盘空间**（不够就用中文报错中止），再导入系统、创建
一块 32GB 的动态数据磁盘并初始化、把它接入开机流程，并注册一个登录时自动挂载磁盘的计划
任务（如需跳过，给脚本加 `-NoTask`）。导入采用**三级回退**：优先把下载的分片**流式**喂给
`wsl --import <发行版> <目录> -`（WSL2 自带的 bsdtar 直接解 zstd，**不下载 `zstd.exe`**、
不合并分片、不产生中间 `.tar`），失败才合并分片后按文件导入，最后才下载 `zstd.exe` 解压为
`.tar`；因此**正常路径在 Windows 11 和 Windows 10 上都不会下载 `zstd.exe`**。装完会校验
发行版确实注册成功，失败则注销这次残缺的注册并给出可操作的中文提示；临时文件（分片 /
合并出的 `.zst` / 解压出的 `.tar`）在**成功和失败后都会清理**。重复运行也没问题。

两个变体现在**互不冲突、可以同时安装同时运行**：agents 版注册成 WSL 发行版 `agent-devbox`
（默认安装目录 `D:\WSL\agent-devbox`），core 版注册成 `agent-devbox-core`
（默认 `D:\WSL\agent-devbox-core`）；各自在自己安装目录里有**独立**的 `data.vhdx`
（两份 `/home`、`/root`、`/workspace` 互不共享）。数据盘统一用 ext4 卷标 **`devbox-data`**
（`DATA_MNTNAME` 也是 `devbox-data`），在 WSL 里固定挂到 **`/mnt/devbox-data`**；安装器
写 `/etc/agent-devbox.conf`（仍是 5 个键）并注册一个**只做附加**的登录计划任务（agents 为
`agent-devbox-mount-datadisk`，core 为 `agent-devbox-core-mount-datadisk`）。

这块计划任务是**隐藏**的：它的动作是一个 `-WindowStyle Hidden -EncodedCommand` 的
PowerShell，只运行 `wsl --mount --vhd "<vhdx>" --bare`（只附加，**不带** `--type ext4` /
`--name`），因此不会再闪出那个空白控制台窗口。真正的 `mount -t ext4` 交给**纯 Linux** 的
开机脚本 —— `scripts/wsl-boot.sh` 现在只在 Linux 侧按 UUID（`blkid -U`）找到已附加的块设备、
挂到 `/mnt/devbox-data`，**再也不会调用 `wsl.exe` / `schtasks.exe`**（旧版从开机里回调
Windows 工具会重进 WSL，造成开不机的死循环）。挂载失败则进入维护模式（fail closed，什么都
不初始化、不启动），并在 `/etc/motd` 里用中英文提示你重跑 Windows 安装器
（`irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex`）。

安装器还会把几个**手动排障脚本**复制进安装目录：`mount-datadisk.cmd` / `mount-datadisk.ps1`
（不带参数＝附加本目录的 `data.vhdx`；`-Vhdx "D:\其它\x.vhdx"`＝附加指定磁盘；再加
`-Name mydisk`＝附加并自动挂到 `/mnt/wsl/mydisk`）和 `unmount-datadisk.cmd` /
`unmount-datadisk.ps1`（`wsl --unmount` 分离）。注意：平时停止发行版只用 `wsl --terminate <发行版>`（磁盘附加不会丢）。`wsl --shutdown` 会关闭
**所有**发行版并分离已挂载的 VHDX——只有改完镜像网络、安装器明确提示并询问 `y/N`、你输入 y 时
才会执行。只有重启 Windows 后首次启动才需要重新附加（跑 `mount-datadisk.cmd`、重跑安装器，
或注销/重新登录触发计划任务）。已装的旧版本建议重跑一次安装器，以采用新的任务
动作和新的 `DATA_MNTNAME=devbox-data`（旧配置也能用：会继续按它旧的 `DATA_MNTNAME` 挂载）。

详见 **[docs/installation-wsl.md](docs/installation-wsl.md)** 和
**[docs/wsl-persistence.md](docs/wsl-persistence.md)**。

## 日志与密码（WSL）

为降低杀软误报，安装脚本**不会把 paseo 密码打印到控制台或安装日志**。安装后这样取：

```powershell
# Windows 侧（先跑上面那段定义 $Distro；也可直接把 $Distro 换成 agent-devbox / agent-devbox-core）
wsl -d $Distro -u root -e cat /etc/agent-devbox.conf
```

```bash
# 已经进了 WSL 的话，不要再写 wsl -d ...，直接：
cat /etc/agent-devbox.conf
```

安装日志**持久保存**在安装目录（默认 agents 为 `D:\WSL\agent-devbox`，core 为
`D:\WSL\agent-devbox-core`），文件名形如 `agent-devbox-install-<yyyyMMdd-HHmmss>.log`；
`%LOCALAPPDATA%` 下的那份只是临时转播日志，原窗口回显后即删除：

```powershell
Get-ChildItem 'D:\WSL\agent-devbox\agent-devbox-install-*.log' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Tail 200
```

其它常用日志（Windows 侧用 `$Distro`；已经在 WSL 里就去掉 `wsl -d $Distro -u root -e` 前缀）：

```powershell
# WSL 开机日志（数据盘挂载 / bind 校验 / 是否进维护模式）
wsl -d $Distro -u root -e tail -n 200 /var/log/agent-devbox-boot.log
# 维护模式横幅
wsl -d $Distro -u root -e cat /etc/motd
# paseo 服务日志
wsl -d $Distro -u root -e tail -n 200 /var/log/paseo-boot.log
# 桌面版能否发现本发行版的 CLI（只读自查）
wsl -d $Distro -u root -e desktop-cli-check.sh --home /root --also-home /home/paseo
# Docker 模式
docker compose logs -f
# CI（GitHub Actions）
gh run list --workflow build.yml --limit 5
gh run view <run-id> --log
```

### wsl-ui 进不去终端（`WSL_E_DISTRO_NOT_FOUND`）

重装 / 升级是**注销后重新导入**发行版，WSL 会给它一个**新的 GUID**（名字不变）。wsl-ui 和
Windows Terminal 里可能还留着**旧 GUID**，于是报
`Wsl/Service/CreateInstance/ReadDistroConfig/WSL_E_DISTRO_NOT_FOUND`。
发行版本身没坏——`wsl -d $Distro` 能进就说明注册正常。按顺序处理：

1. 跑上面那段 `$Distro` 代码（`wsl --set-default` 是可选的，安装器不会替你改默认发行版）；
2. 在 wsl-ui 里对该发行版点 **Sync / 刷新**，或删掉旧条目后重新添加；
3. 还不行：关掉 wsl-ui 与 Windows Terminal，清掉 wsl-ui 的缓存后重开（它只是展示用的元数据）：

```powershell
Stop-Process -Name wsl-ui -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\wsl-ui\distro-metadata.json" -Force -ErrorAction SilentlyContinue
```

4. Windows Terminal 的 profile 由安装器**固定 GUID**：镜像里关掉了 WSL 的自动 profile 生成
   （`/etc/wsl-distribution.conf` 的 `[windowsterminal] enabled=false`），安装器写一条
   `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\AgentDevbox\<发行版>.json`
   （固定 GUID、`wsl.exe -d <发行版>` 启动、起始目录 `/root`），并删掉 WSL 以前生成的
   `Fragments\Microsoft.WSL` 旧条目。重装/升级都不会换 GUID，你在 profile 上的字体/配色/
   起始目录会一直保留。若 wsl-ui 仍打不开终端，关掉 Windows Terminal 与 wsl-ui 后重开。

## 运行身份

- 你登录用的用户：**root**。
- paseo 后台服务：以非 root 的 **`paseo`** 用户运行（uid/gid 1000）。
- `PASEO_PASSWORD` **必填** —— 没设置密码时服务会拒绝启动。

## 端口

- **6767** —— paseo 后台服务 + 网页界面（Docker 模式下只对外开这一个端口）。
- **4096** —— `opencode serve`（默认只监听 `127.0.0.1`），见
  [docs/opencode-expose.md](docs/opencode-expose.md)。

## 组网访问（EasyTier mesh）

不想把 paseo 暴露在公网，又想用手机随时访问？可以在 VPS 上用
[EasyTier](https://github.com/EasyTier/EasyTier) 组一个虚拟局域网；设备加入同一个网络后，
直接用节点的虚拟 IP 访问容器里的 paseo（优先 P2P 直连，延迟通常比官方中继低）。

**agent-devbox 不用改**：保持 `6767:6767` 即可。它发布在 `0.0.0.0`，已经覆盖了 EasyTier
的虚拟网卡，mesh 里的设备访问“节点虚拟 IP 的 6767”会被直接转发进容器。

最简单用法：

1. **VPS 上跑 EasyTier（`network_mode: host`）并加入你的网络**（`--network-name` /
   `--network-secret`），建议固定一个虚拟 IP，例如 `-i 10.126.126.1`。
2. 照常 `docker compose up -d`（设好 `PASEO_PASSWORD`），**不用加任何端口 / 网络配置**。
3. **手机装 EasyTier 客户端**，加入同一个网络。
4. 手机浏览器打开 **`http://10.126.126.1:6767`**，输入 `PASEO_PASSWORD`。

> 用 IP 访问无需额外配置；只有改用**域名**访问时才需要设置 `PASEO_HOSTNAMES`。

> 不想公网也能访问 6767？在 VPS 的**云安全组**里不放行 6767 即可 —— 不影响 mesh，
> 因为 mesh 流量走 EasyTier 虚拟网卡，不经过公网网卡。

完整说明（EasyTier 参数、虚拟 IP 查询、防火墙收紧、原理）见
**[docs/mesh-access.md](docs/mesh-access.md)**。

## 构建

**禁止在本地构建 / 编译** —— 又慢，又会在本机产生大量垃圾。镜像和所有产物**只在 GitHub Actions 里生成**：

- 推送到**任意分支**都会自动构建；定时（每 3 天一次）和手动触发也会构建；
- 每次构建都同时产出 **amd64 + arm64**，再合并成一个多架构镜像
  （用 GitHub 免费的原生 ARM 机器，不做模拟）；
- 定时构建时，如果所有跟踪的上游版本都没变，会自动跳过
  （靠 `versions.json` 做比对）；
- **只有 定时 / 手动 才会把镜像推为 `latest` 并创建 Release**；推送触发的构建只产出**测试标签**，
  不会覆盖 `latest`：
  - main 分支 → 镜像标签 `<YYYYMMDD.HHMM>`，预发布为 `beta-<YYYYMMDD.HHMM>`
  - 其他分支 → 镜像标签和预发布都是 `beta-<YYYYMMDD.HHMM>`
  - 每次 push 还会把 **`:beta` 镜像别名**移到这次最新的推送构建上
  - 旧的 `beta-*` 预发布会被**清理**，只保留最新一个（每个约 4.7GB）
- 先给候选版本做冒烟测试，通过后才更新 `latest`。

> **想测试最新构建（这些不进 `latest` 的版本）**：
> ```bash
> # 最新的推送构建（多架构；`:beta` 始终指向最新一次 push）
> docker pull ghcr.io/sfhgknsdfksdlf/agent-devbox:beta
> # 某次具体构建（<标签> 换成该次运行页面显示的 YYYYMMDD.HHMM 或 beta-YYYYMMDD.HHMM）
> docker pull ghcr.io/sfhgknsdfksdlf/agent-devbox:<标签>
> ```
> 每次 push 还会把 **WSL rootfs 分片 + 1Panel 包**传到**日期化的预发布**（Releases 里
> tag 为 `beta-<YYYYMMDD.HHMM>` 的那个；只保留最新一个，旧的会被自动清理）。用 WSL 测这个版本：
> **运行上面那条 `irm` 一行命令，安装脚本会问要装哪个** —— 回车＝正式版（`latest`），输入 `b`／`beta`
> ＝最新的 `beta-*` 预发布（脚本经 GitHub API 解析），或直接输入某个版本号
> （`build-YYYYMMDD.HHMM`／`beta-YYYYMMDD.HHMM`，裸日期如 `20261018.0731` 会自动补 `build-` 前缀）。
> **已装过会直接覆盖升级，不再问 y/N** —— 换系统盘，但数据盘（`/home`、`/root`、`/workspace`）
> 和 **paseo 密码都保留**（密码存在数据盘 `/mnt/devbox-data/.paseo-password`）。想保留现有安装不动就加
> `-KeepExisting`；无人值守用 `-ReleaseTag <版本>`（`-Yes` 现在也会升级）。稳定版仍是定时的
> `latest` / Release。

## 产物在哪

| 产物 | 位置 | 给谁用 |
|---|---|---|
| 容器镜像（`agent-devbox`、`agent-devbox-core`，多架构） | **ghcr.io** | Docker 用户；WSL 的 wsl-ui 导入 |
| WSL 镜像包（`rootfs-*.tar.zst.part-*`，分片） | **GitHub Releases** | Windows 一键安装（`irm` 命令读取） |
| Windows 安装入口（`irm` 一行命令） | **项目源码 `main`**（`windows/install.ps1`） | 第一次安装的入口 |
| 1Panel 本地应用包（`agent-devbox-1panel-localapp.zip`） | **GitHub Releases** | 1Panel 应用商店（本地应用） |

> Windows 端**不再**随 Release 分发旧的安装压缩包或独立的引导脚本；安装入口
> 就是项目源码 `main` 上的 `windows/install.ps1`（`irm ... | iex`）。它按需从 `main` 取回
> `install-agent-devbox.ps1`、`wsl-ensure.ps1`、`wsl-ensure-downloads.ps1`，并把手动挂载 / 卸载
> 数据盘的辅助脚本 `mount-datadisk.ps1`、`mount-datadisk.cmd`、`unmount-datadisk.ps1`、
> `unmount-datadisk.cmd` 复制进安装目录。Release 现在只承载 rootfs 分片和 1Panel 本地应用包。

> 结论：**容器镜像在 ghcr**；**Windows 一键安装的入口是项目源码里的 `install.ps1`（`irm`）**，
> **给 WSL 用的 rootfs 分片在 GitHub Releases**。
> 之所以不把 WSL 包也放进 ghcr：WSL 导入需要"扁平的文件系统 tar"，没法直接当 OCI 镜像用。
> 正常情况下导入直接用 WSL2 自带的 zstd 解压（Windows 11/10 都不需要额外程序）；只有在最后
> 兜底的 Tier 3 才会**按固定版本**从 facebook/zstd 官方项目下载 `zstd.exe`，我们不转发第三方程序。

> 注意：公开仓库里的定时任务如果 60 天没有任何活动会被 GitHub 自动关掉 ——
> `keepalive` 工作流会定期提交一次来避免。

## 目录结构

```
Dockerfile              # 精简版镜像
Dockerfile.agents       # 默认的多助手版镜像（基于精简版）
docker-compose.yml      # 只拉取（Docker 模式）
1panel/                 # 1Panel 商店本地应用包
scripts/                # 入口、启动、初始化、数据盘初始化
config/                 # wsl.conf、profile.d
windows/                # 安装入口 install.ps1（irm | iex）+ 安装脚本 install-agent-devbox.ps1 + 共享辅助 wsl-ensure.ps1 / wsl-ensure-downloads.ps1 + 手动挂载 / 卸载辅助 mount-datadisk.* / unmount-datadisk.*
.github/workflows/      # build.yml、keepalive.yml
docs/                   # 软件清单、基础镜像、问答、安装、数据持久化、组网访问
tests/                  # bats 测试（tests/run.sh）+ PowerShell 单元测试（tests/powershell）
```

## 文档

- [软件清单与分类](docs/software-inventory.md)
- [基础镜像分析](docs/base-image-analysis.md)
- [额外的 AI 助手与常见搭配](docs/agents-companions.md)
- [问答 / 设计取舍](docs/qa.md)
- [桌面 App 的 CLI 检测要求](docs/desktop-cli-detection.md)
- [Docker 安装](docs/installation-docker.md)
- [WSL 安装](docs/installation-wsl.md)
- [1Panel 安装](docs/installation-1panel.md)
- [WSL 数据持久化](docs/wsl-persistence.md)
- [对外暴露 OpenCode](docs/opencode-expose.md)
- [组网访问（EasyTier mesh）](docs/mesh-access.md)

## 许可

MIT —— 见 [LICENSE](LICENSE)。
