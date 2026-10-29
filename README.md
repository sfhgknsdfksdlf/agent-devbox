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
- 安装脚本（`install-agent-devbox.ps1`、`wsl-ensure.ps1`、`wsl-ensure-downloads.ps1`）从**所选的代码分支/标签（默认 `main`）**取回，只有 rootfs 镜像分片来自 Release；每个脚本都会按同分支的 `windows/SHA256SUMS` 校验（旧版本没有清单时才需要 `-AllowUnverifiedScripts`）；rootfs 分片按架构命名（`rootfs-<variant>-<arch>.tar.zst.part-*`，`arch` 为 `amd64` / `arm64`），安装器按宿主**原生**架构自动选择，不需要额外参数；
- 交互运行时询问装哪个镜像（回车＝完整版多助手 `agents`，输入 `c`＝精简版 `core`）和哪个版本（回车＝`latest`，输入 `b`＝最新 `beta`，也可直接输入版本号），最后询问代码分支（回车＝`main`，输入 `?` 列出全部分支；非 `main` 的 ref 会装进完全隔离的 beta 通道，见下文）；
- 装完自动清理临时文件。

装好后用**哪个名字取决于「变体 × 通道」**：正式通道是 `agent-devbox`（多助手 agents）和
`agent-devbox-core`（core），beta 通道是 `agent-devbox-beta` 和 `agent-devbox-core-beta`。
记不住、或者怕粘贴错，就在 Windows PowerShell 里粘一次下面这段——它按通道自动认出已装的发行版并设为默认：

```powershell
$env:WSL_UTF8 = 1
$Channel = 'stable'   # 装的是 beta 通道就改成 'beta'
$names = @('agent-devbox', 'agent-devbox-core', 'agent-devbox-beta', 'agent-devbox-core-beta')
$Distro = (wsl -l -q) | ForEach-Object { ($_ -replace "`0", '').Trim() } |
  Where-Object {
    $_ -in $names -and
    (($_ -notlike '*-beta') -eq ($Channel -eq 'stable'))
  } | Select-Object -First 1
if (-not $Distro) { throw "没找到 $Channel 通道的 agent-devbox（$($names -join ' / ')），请先跑上面那条安装命令" }
wsl --set-default $Distro
"使用发行版：$Distro"
```

之后在**同一个 PowerShell 窗口**里，所有命令都可以直接写 `wsl -d $Distro ...`；不想用变量就显式写
`wsl -d agent-devbox`（agents/stable）、`wsl -d agent-devbox-core`（core/stable）、
`wsl -d agent-devbox-beta`（agents/beta）或 `wsl -d agent-devbox-core-beta`（core/beta）。

安装脚本会自动：**下载前先检查目标磁盘空间**（不够就用中文报错中止），再导入系统、创建
一块 32GB 的动态数据磁盘并初始化、写入开机配置，并自己附加这块数据盘（下次启动起由
`wsl-boot.sh` 在发行版内部自动附加；旧版本留下的 `agent-devbox*-mount-datadisk` 旧任务会被注销）。
导入采用**三级回退**：
优先把下载的分片**流式**喂给
`wsl --import <发行版> <目录> -`（WSL2 自带的 bsdtar 直接解 zstd，**不下载 `zstd.exe`**、
不合并分片、不产生中间 `.tar`），失败才合并分片后按文件导入，最后才下载 `zstd.exe` 解压为
`.tar`；因此**正常路径在 Windows 11 和 Windows 10 上都不会下载 `zstd.exe`**。装完会校验
发行版确实注册成功，失败则注销这次残缺的注册并给出可操作的中文提示；临时文件（分片 /
合并出的 `.zst` / 解压出的 `.tar`）：**成功导入后清理本次下载的分片**；导入失败时保留分片和 sidecar（内容被证明可疑时除外），重跑会重新校验 SHA256 后续传。重复运行也没问题。
**ARM64 例外**：Windows 11 ARM64 上只有 **Tier 1 / Tier 2**；Tier 3 依赖的 `zstd.exe` 只有
x64 版本，因此会跳过 Tier 3。两级都失败时安装器提示先 `wsl --update` 再重装，已下载的分片会
保留供重试（详见 [docs/installation-wsl.md](docs/installation-wsl.md) 的 ARM64 一节）。

四个组合（变体 × 通道）现在**互不冲突、可以同时安装同时运行**：正式通道沿用发行版 `agent-devbox`
（默认安装目录 `D:\WSL\agent-devbox`）和 `agent-devbox-core`（默认 `D:\WSL\agent-devbox-core`）；
beta 通道是 `agent-devbox-beta`（默认 `D:\WSL\agent-devbox-beta`）和 `agent-devbox-core-beta`
（默认 `D:\WSL\agent-devbox-core-beta`）。每个组合在自己的安装目录里有**独立**的 `data.vhdx`
（`/home`、`/root`、`/workspace` 互不共享）。数据盘的 ext4 卷标和挂载名**按通道区分**：正式通道是
**`devbox-data`**，beta 通道是 **`devbox-data-beta`**（正好 16 个字符，ext4 卷标上限），分别固定挂到
**`/mnt/devbox-data`** 和 **`/mnt/devbox-data-beta`**；安装器写 `/etc/agent-devbox.conf`
（6 个键：`DATA_VHDX`、`DATA_UUID`、`DATA_LABEL`、`PASEO_PASSWORD`、`DATA_MNTNAME`、`DATA_DISTRO`）。
安装器只自己附加一次数据盘，**不再注册任何 Windows 任务**；
如果检测到旧版本留下的 `agent-devbox-mount-datadisk` / `agent-devbox-core-mount-datadisk`
旧任务，会直接注销它们。

真正的挂载由**发行版自己在每次启动时完成**：`scripts/wsl-boot.sh` 先发起一次**硬超时**的
`wsl.exe --mount --vhd ... --bare`（设备已在则跳过；这是 `[boot]` 里唯一一次 interop 调用），
再等待设备出现、按 UUID（`blkid -t UUID=`）找到它（找不到再按本通道的标签 `devbox-data` / `devbox-data-beta`），挂到
`/mnt/<DATA_MNTNAME>`（`/mnt/devbox-data` 或 `/mnt/devbox-data-beta`），最后 bind
`/home` `/root` `/workspace`。它**不调用** `schtasks.exe`、`wsl -d` 或 `--unmount`
（旧版从开机里回调 Windows 工具会重进 WSL，造成开不机的死循环）。挂载失败则进入维护模式
（fail closed，什么都不初始化、不启动），`/etc/motd` 用中英文给出两条可复制粘贴的修复命令：
先运行 `<安装目录>\mount-datadisk.cmd`，再 `wsl --terminate <发行版>`，然后重新打开发行版
（这一次启动里 boot 会自己挂载）。

安装器还会把两个**纯批处理**手动排障脚本复制进安装目录（不需要 PowerShell，也不需要管理员 /
UAC）：`mount-datadisk.cmd`（不带参数＝附加本目录的 `data.vhdx`，位置参数可指定别的 VHDX 路径；
重试 3 次、写 `datadisk-attach.log`、返回真实的退出码）和 `unmount-datadisk.cmd`
（`wsl --unmount "\\?\<vhdx>"` 分离，已分离时打印 [INFO] 并退出 0；真正的失败仍非 0）。

附加（attach）什么时候会丢，说清楚：

- `wsl --terminate <发行版>` 只停这一个发行版，**保留**附加；
- `wsl --shutdown` 会关闭**所有**发行版并**分离所有已挂载的 VHDX**（这是 WSL 的设计），
  只在改完镜像网络、安装器明确提示并询问 `y/N`、你输入 y 时才执行；
- **重启 Windows 一定丢失附加**：WSL 的自动重挂状态是 **VOLATILE** 注册表键，重启即清空。

正常使用不用管这些：**发行版每次启动，boot 脚本都会自己重新附加并挂载**。只有 boot attach
失败（进了维护模式）时才需要手动修复：先跑 `<安装目录>\mount-datadisk.cmd`，再
`wsl --terminate <发行版>`，然后重新打开发行版。已装的旧版本建议重跑一次安装器：它会注销
旧版本残留的挂载任务，并写入新的 6 键配置（旧配置也能用：会继续按它旧的 `DATA_MNTNAME`
挂载）。

**同一通道内**的两个变体（agents / core）数据盘可以互换：它们用同一个 ext4 卷标（也是挂载名），
正式通道是 `devbox-data`、beta 通道是 `devbox-data-beta`；把一个变体的 `data.vhdx` 复制到**同通道**
另一个变体的安装目录后，boot 会先按 conf 里的 UUID 找设备，找不到再按该通道的标签找，所以复制盘
（保留源 UUID）也能正常挂载，conf 里的 UUID 不会被改写。**跨通道不行**：正式盘不能给 beta 用，
beta 盘也不能给正式用（卷标 / 挂载名不同，安装器的目录所有权校验也会拒绝）。
同一通道内两个变体各自的盘 UUID 不同，同时附加也不会互相误认；但如果 UUID 命中不止一块（复制盘保留了
源 UUID、原盘又还附加着），或 UUID 完全找不到而标签命中多块，boot 会 fail closed 进入维护
模式而不是随便挑一块：按提示用安装目录的 `unmount-datadisk.cmd` 分离多余的那块，再重新打开
发行版。复制出来的两份是彼此独立的文件系统（不会同步），复制前请先分离源盘。

详见 **[docs/installation-wsl.md](docs/installation-wsl.md)** 和
**[docs/wsl-persistence.md](docs/wsl-persistence.md)**。

## Beta 通道（完全隔离）

从**非 `main` 的代码 ref** 安装时，安装器会把这次安装放进 **beta 通道**：
`$Channel = 'beta'` 当且仅当 `$Ref -ne 'main'`，否则是 `stable`。`$Ref` 的取值顺序是
`-Ref` > 环境变量 `$env:AGENT_DEVBOX_REF` > 交互式询问（回车 = `main`）> `main`。

> **关键**：`irm https://raw.githubusercontent.com/<owner>/<repo>/<branch>/windows/install.ps1 | iex`
> 这种写法**拿不到 URL 里的分支名**。只改 URL 里的分支，安装的仍然是 `main` 的脚本，并且会装进
> **stable** 通道。要从某个分支安装，必须显式传 `-Ref <branch>`，或先设置
> `$env:AGENT_DEVBOX_REF = '<branch>'`：

```powershell
# 方式一：环境变量（对后面的 irm | iex 生效）
$env:AGENT_DEVBOX_REF = 'my-branch'
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex

# 方式二：直接给入口脚本传 -Ref
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1))) -Ref my-branch
```

beta 通道会在发行版名、默认安装目录、数据盘 ext4 卷标和挂载名上追加 `-beta`：

| 变体 | 通道 | 发行版 | 默认安装目录 | ext4 卷标 | 挂载名 |
|---|---|---|---|---|---|
| agents | stable | `agent-devbox` | `D:\WSL\agent-devbox` | `devbox-data` | `devbox-data` |
| agents | beta | `agent-devbox-beta` | `D:\WSL\agent-devbox-beta` | `devbox-data-beta` | `devbox-data-beta` |
| core | stable | `agent-devbox-core` | `D:\WSL\agent-devbox-core` | `devbox-data` | `devbox-data` |
| core | beta | `agent-devbox-core-beta` | `D:\WSL\agent-devbox-core-beta` | `devbox-data-beta` | `devbox-data-beta` |

`devbox-data-beta` 正好 16 个字符（ext4 卷标上限）。**同一通道内** agents / core 的数据盘仍可互换；
**跨通道不行**，正式盘与 beta 盘不通用。

显式 `-InstallDir` 会**原样使用，绝不追加 `-beta`**。一个目录只属于一个通道：如果目录里已经有
`data.vhdx` **或** `ext4.vhdx`，安装器会读 `<目录>\.agent-devbox-channel`（没有标记 = 通道功能之前
的旧安装，按 `stable` 处理）；通道不一致时直接拒绝，并提示去掉 `-InstallDir` 用默认目录，或换一个
新目录。这样 beta 安装不会覆盖正式安装的系统盘或数据盘。

stable 与 beta 可以同时安装、同时运行：发行版、安装目录、`data.vhdx`、paseo 密码、Windows Terminal
fragment（beta 是 `agent-devbox-beta.json` / `agent-devbox-core-beta.json`）以及固定 GUID 都各自独立。
`%LOCALAPPDATA%\agent-devbox` 下的暂存目录是两者共用的，但每次运行都用随机子目录，互不覆盖。

仍然有几项是**主机级**的，beta 安装也躲不开：`.wslconfig`（例如镜像网络）、`Set-MirroredNetworking`
和 `wsl --shutdown` 影响整台机器，一次 beta 安装同样可能改动主机网络设置或停掉其它发行版。

数据盘初始化（`datadisk-init`：卷标不合法、候选盘有歧义、`mkfs` 失败等）现在**直接失败**，不再继续
写配置，因此另一个通道的磁盘 UUID / 密码不会被写进本通道的 `/etc/agent-devbox.conf`；失败时
`data.vhdx` 保留，方便重试或换目录。

> beta **通道**不是 beta **发布**：上文的 `beta-<YYYYMMDD.HHMM>` / `:beta` 是 Release / 镜像标签，
> `-ReleaseTag b|beta` 选的是最新的 `beta-*` 预发布（rootfs）；`-Ref` 选的才是代码分支。
> beta 通道用正式 rootfs 或 beta rootfs 都行，**前提是该 rootfs 里的 `wsl-boot.sh` 支持通道标签
> （`DATA_LABEL`）**；更旧的镜像会被直接拒绝：安装器注销刚导入的发行版、保留 `data.vhdx`，并提示改用
> `-ReleaseTag beta` 或更新的构建。
> 另外，只有包含 beta 通道实现的 ref 才会装出 beta 通道；更旧的标签 / commit 里还是没加 `-Channel`
> 的旧 `install.ps1`，会按 stable 入口安装。

## 日志与密码（WSL）

为降低杀软误报，安装脚本**不会把 paseo 密码打印到控制台或安装日志**；交互输入密码时也**不回显**（`Read-Host -AsSecureString`）。安装后这样取：

```powershell
# Windows 侧（先跑上面那段定义 $Distro；也可直接把 $Distro 换成
# agent-devbox / agent-devbox-core / agent-devbox-beta / agent-devbox-core-beta）
wsl -d $Distro -u root -e cat /etc/agent-devbox.conf
```

```bash
# 已经进了 WSL 的话，不要再写 wsl -d ...，直接：
cat /etc/agent-devbox.conf
```

每个通道的 `PASEO_PASSWORD` 各自独立，互不沿用；数据盘上的副本也在各自的挂载点：
`/mnt/devbox-data/.paseo-password`（stable）或 `/mnt/devbox-data-beta/.paseo-password`（beta）。

安装日志**持久保存**在安装目录（正式通道 agents 为 `D:\WSL\agent-devbox`、core 为
`D:\WSL\agent-devbox-core`；beta 通道为 `D:\WSL\agent-devbox-beta` /
`D:\WSL\agent-devbox-core-beta`），文件名形如 `agent-devbox-install-<yyyyMMdd-HHmmss>.log`；
`%LOCALAPPDATA%` 下的那份只是临时转播日志，原窗口回显后即删除：

```powershell
$InstallDir = 'D:\WSL\agent-devbox'   # beta：D:\WSL\agent-devbox-beta；core 同理
Get-ChildItem "$InstallDir\agent-devbox-install-*.log" |
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
   （固定 GUID、`wsl.exe -d <发行版>` 启动、起始目录 `/root`；beta 通道的发行版名自带 `-beta`，
   例如 `agent-devbox-beta.json`），并删掉 WSL 以前生成的
   `Fragments\Microsoft.WSL` 旧条目、以及**已不存在发行版**的 AgentDevbox fragment（stable/beta
   同时安装时各自的 profile 都会保留）。重装/升级都不会换 GUID，你在 profile 上的字体/配色/
   起始目录会一直保留。若 wsl-ui 仍打不开终端，关掉 Windows Terminal 与 wsl-ui 后重开。

### wsl-ui 报 `0x8007010b`（无法访问启动目录）

现象：点 wsl-ui 的终端按钮后，Windows Terminal 弹
`[出现错误 2147942667 (0x8007010b) (启动"wsl -d <发行版> --cd ~"时)]`
`无法访问启动目录 "\\wsl$\<旧发行版>\root"`。

原因：**已删除的发行版**还留着自己的 WT fragment
（`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\AgentDevbox\<旧发行版>.json`），
其中的 `startingDirectory` 指向已经不存在的 `\\wsl$\<旧发行版>\root`。Windows Terminal 会把
profile 缓存在进程里，所以注销/重装/换通道后仍可能命中旧目录。

处理：

1. 安装器现在写完自己的 fragment 后会按 `wsl -l -q` 清理**未注册**发行版的 AgentDevbox
   fragment（stable 与 beta 同时安装时各自保留）。已有旧 fragment 的机器重跑一次安装器，
   或手工删除 `Fragments\AgentDevbox\<旧发行版>.json`；
2. **完全退出所有 Windows Terminal 窗口**（不是只关 tab，WT 进程要退出）再重开——运行中的
   WT 不会重新读取 fragment；
3. 若 profile 仍出现在 WT 列表里：在设置里删除该 profile，或在 `settings.json` 删掉对应条目后重开。

> `distro-metadata.json` 的清理只用于上面的 `WSL_E_DISTRO_NOT_FOUND`，与本错误无关。

## 运行身份

- 你登录用的用户：**root**。
- paseo 后台服务：以非 root 的 **`paseo`** 用户运行（uid/gid 1000）。
- `PASEO_PASSWORD` **必填** —— 没设置密码时服务会拒绝启动。stable 与 beta 通道各自有一份密码，互不沿用。

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
- **WSL rootfs 分片现在也同时产出 amd64 + arm64**：两个架构各自在**原生 runner** 上导出
  （amd64 用 `ubuntu-latest`、arm64 用 `ubuntu-24.04-arm`），上传为临时 artifact，再由发布
  任务下载两套分片、校验分片编号连续，写一份**覆盖两架构的 `SHA256SUMS`**，最后创建 Release；
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
> **已装过时，交互式运行会问一行：回车 = 覆盖升级，`n` = 取消** —— 换系统盘，但数据盘
> （`/home`、`/root`、`/workspace`）和 **paseo 密码都保留**（密码存在数据盘
> `/mnt/<DATA_MNTNAME>/.paseo-password`：正式通道 `devbox-data`，beta 通道 `devbox-data-beta`）。一键命令会在 UAC 提权之后、改动镜像网络之前提问；
> 取消就什么都不做（不下载、不注销、不改 `.wslconfig`，退出码 0）。想保留现有安装不动就加
> `-KeepExisting`；`-Yes` 或重定向/无人值守运行不提问，直接升级；无人值守还可用
> `-ReleaseTag <版本>`。稳定版仍是定时的 `latest` / Release。
> 这里的 beta 是**发布标签**，和上面的 beta **通道**不是一回事：`-ReleaseTag b` 只换 rootfs，
> 通道由 `-Ref` 决定（见「Beta 通道（完全隔离）」）。

## 产物在哪

| 产物 | 位置 | 给谁用 |
|---|---|---|
| 容器镜像（`agent-devbox`、`agent-devbox-core`，多架构） | **ghcr.io** | Docker 用户；WSL 的 wsl-ui 导入 |
| WSL 镜像包（`rootfs-<variant>-<arch>.tar.zst.part-*`，分片；`arch` 为 `amd64` / `arm64`） | **GitHub Releases** | Windows 一键安装（`irm` 命令读取，按宿主架构自动选择） |
| Windows 安装入口（`irm` 一行命令） | **项目源码 `main`**（`windows/install.ps1`） | 第一次安装的入口 |
| 1Panel 本地应用包（`agent-devbox-1panel-localapp.zip`） | **GitHub Releases** | 1Panel 应用商店（本地应用） |

> Windows 端**不再**随 Release 分发旧的安装压缩包或独立的引导脚本；安装入口
> 就是项目源码 `main` 上的 `windows/install.ps1`（`irm ... | iex`）。它按需从**所选 ref（默认 `main`）**
> 取回 `install-agent-devbox.ps1`、`wsl-ensure.ps1`、`wsl-ensure-downloads.ps1`，并把手动挂载 / 卸载
> 数据盘的辅助脚本 `mount-datadisk.cmd`、`unmount-datadisk.cmd` 复制进安装目录。Release
> 现在只承载 rootfs 分片和 1Panel 本地应用包。从分支安装必须传 `-Ref <分支>`（或设
> `$env:AGENT_DEVBOX_REF`），否则装的是 `main` 脚本 + stable 通道。

> 结论：**容器镜像在 ghcr**；**Windows 一键安装的入口是项目源码里的 `install.ps1`（`irm`）**，
> **给 WSL 用的 rootfs 分片在 GitHub Releases**。
> 之所以不把 WSL 包也放进 ghcr：WSL 导入需要"扁平的文件系统 tar"，没法直接当 OCI 镜像用。
> 正常情况下导入直接用 WSL2 自带的 zstd 解压（Windows 11/10 都不需要额外程序）；只有在最后
> 兜底的 Tier 3 才会**按固定版本**从 facebook/zstd 官方项目下载 `zstd.exe`，我们不转发第三方程序。
> Tier 3 只在 x64 上存在：Windows 11 ARM64 使用 Tier 1 / Tier 2。
>
> 每个 Release **同时携带 amd64 与 arm64 两套分片**，以及一份覆盖两架构的 `SHA256SUMS`。
> 旧 Release 只有 amd64 分片：在 ARM64 上安装会在**下载前**以 `没有 ARM64 分片` 明确失败，
> 并提示改用 `-ReleaseTag latest` / `beta` 或在 x64 上安装。**没有 amd64 回退**：WSL2 不模拟
> x86-64 Linux ELF，amd64 的 rootfs 在 ARM64 上无法启动。Windows 10 ARM64 不受支持。

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
windows/                # 安装入口 install.ps1（irm | iex）+ 安装脚本 install-agent-devbox.ps1 + 共享辅助 wsl-ensure.ps1 / wsl-ensure-downloads.ps1 + 手动挂载 / 卸载辅助 mount-datadisk.cmd / unmount-datadisk.cmd
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
