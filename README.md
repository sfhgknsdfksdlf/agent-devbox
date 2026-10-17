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

标签：`YYYYMMDD.HHMM`（例如 `20261017.2205`）和 `latest`。

## 快速开始 —— Docker

```bash
cp .env.example .env      # 设置 PASEO_PASSWORD（必填）
docker compose up -d
# 浏览器打开 http://localhost:6767
```

## 快速开始 —— WSL

1. 到 **[最新 Release](https://github.com/sfhgknsdfksdlf/agent-devbox/releases/latest)** 下载
   **`agent-devbox-windows.zip`** 并解压（安装脚本都在里面）。
2. 双击 **`agent-devbox.bat`**（默认，多助手版）或 **`agent-devbox-core.bat`**（精简版），
   同意一次管理员授权（UAC）。
3. 执行 `wsl -d agent-devbox`

**一行安装**（不想手动下载也可以）：

```powershell
irm https://raw.githubusercontent.com/sfhgknsdfksdlf/agent-devbox/main/windows/install.ps1 | iex
```

会自动请求管理员权限、自动装好 WSL 并建议开启镜像网络，装完自动清理临时文件。

安装脚本会自动：导入系统、创建一块 32GB 的动态数据磁盘并初始化、把它接入开机流程，
并（可选）注册一个登录时自动挂载磁盘的计划任务。重复运行也没问题。

详见 **[docs/installation-wsl.md](docs/installation-wsl.md)** 和
**[docs/wsl-persistence.md](docs/wsl-persistence.md)**。

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
  - main 分支 → 日期标签 `YYYYMMDD.HHMM`
  - 其他分支 → 统一的 `beta` 标签（每次 push 覆盖）
- 先给候选版本做冒烟测试，通过后才更新 `latest`。

> **想测试最新构建（这些不进 `latest` 的版本）**：
> ```bash
> # 其他分支（beta，多架构）
> docker pull ghcr.io/sfhgknsdfksdlf/agent-devbox:beta
> # main 分支（<标签> 换成该次运行页面显示的 YYYYMMDD.HHMM）
> docker pull ghcr.io/sfhgknsdfksdlf/agent-devbox:<标签>
> ```
> 每次 push 还会把 **WSL rootfs + Windows 安装包 + 1Panel 包**传到 **`beta` 预发布**（Releases 里
> tag 为 `beta` 的那个）。用 WSL 测这个版本：**双击 `agent-devbox.bat` 跑安装脚本时会问要装哪个** ——
> 每次都问要装哪个：回车＝正式版（`latest`），输入 `b`＝`beta` 测试版，或直接输入某个版本号
> （如 `build-20261018.0731`）。**已装过会再问「是否用新版本重装」——确认后重装发行版，数据盘
> （`/home`、`/root`、`/workspace`）保留**，方便本地反复切换。无人值守时用 `-ReleaseTag <版本>`；
> 稳定版仍是定时的 `latest` / Release。

## 产物在哪

| 产物 | 位置 | 给谁用 |
|---|---|---|
| 容器镜像（`agent-devbox`、`agent-devbox-core`，多架构） | **ghcr.io** | Docker 用户；WSL 的 wsl-ui 导入 |
| WSL 镜像包（`rootfs-*.tar.zst.part-*`，分片） | **GitHub Releases** | Windows 双击安装脚本 |
| Windows 安装包（`agent-devbox-windows.zip`；Release 只提供这个 zip，不再单独附 `.bat`/`.ps1`） | **GitHub Releases**（每个 Release 附带） | 第一次安装的入口 |
| 1Panel 本地应用包（`agent-devbox-1panel-localapp.zip`） | **GitHub Releases** | 1Panel 应用商店（本地应用） |

> 结论：**容器镜像在 ghcr**；**给 Windows 一键安装用的打包文件在 GitHub Releases**。
> 之所以不把 WSL 包也放进 ghcr：WSL 导入需要"扁平的文件系统 tar"，没法直接当 OCI 镜像用。
> Windows 解压用的 `zstd.exe`（Win10 不自带）由安装脚本**按固定版本**从 facebook/zstd 官方项目下载，
> 我们不转发第三方程序。

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
windows/                # 一键安装脚本（.ps1）+ 启动器（.bat）+ 导入脚本
.github/workflows/      # build.yml、keepalive.yml
docs/                   # 软件清单、基础镜像、问答、安装、数据持久化、组网访问
tests/                  # bats 测试
```

## 文档

- [软件清单与分类](docs/software-inventory.md)
- [基础镜像分析](docs/base-image-analysis.md)
- [额外的 AI 助手与常见搭配](docs/agents-companions.md)
- [问答 / 设计取舍](docs/qa.md)
- [Docker 安装](docs/installation-docker.md)
- [WSL 安装](docs/installation-wsl.md)
- [1Panel 安装](docs/installation-1panel.md)
- [WSL 数据持久化](docs/wsl-persistence.md)
- [对外暴露 OpenCode](docs/opencode-expose.md)
- [组网访问（EasyTier mesh）](docs/mesh-access.md)

## 许可

MIT —— 见 [LICENSE](LICENSE)。
