# Agent Devbox（1Panel 本地应用）

一个"装好就能用"的 AI 开发 / 测试环境：内置 **paseo**（后台服务 + 自带网页界面）、
**OpenCode V1**、**omo**，以及 Go / Python / Node / Bun / Playwright 等工具链。

> 1Panel 里的这个应用，和仓库里 **Docker 模式**、**WSL 模式**用的是**同一个镜像**
> （`ghcr.io/sfhgknsdfksdlf/agent-devbox`），只是换了一种安装入口。

## 安装步骤

1. 把本目录（`agent-devbox/`）整个放到 1Panel 的本地应用目录：

   ```text
   /opt/1panel/resource/apps/local/agent-devbox/
   ```

   放好之后的路径应该是 `/opt/1panel/resource/apps/local/agent-devbox/data.yml`。

2. 打开 1Panel 的 **应用商店**，点击 **「同步本地应用」**，列表里就会出现
   **Agent Devbox**。

3. 点击 **安装**，按需填写：

   | 字段 | 说明 | 默认值 |
   |---|---|---|
   | **网页端口** | 对外访问的宿主机端口 | `6767` |
   | **访问密码** | `PASEO_PASSWORD`，**必填**（不设置后台服务会拒绝启动） | `change-me-please`（请务必修改） |
   | **时区** | 容器时区 | `Asia/Shanghai` |

4. 安装完成后，浏览器打开 `http://<服务器IP>:<网页端口>`（默认
   `http://<服务器IP>:6767`）即可进入网页界面。

## 数据与持久化

容器把数据写在应用目录下的 `./data/`：

- `./data/home` → 容器内 `/home/paseo`（paseo 服务的数据）
- `./data/project` → 容器内 `/workspace`（工作目录）

删除应用前请先备份 `./data/`。

## 说明

- 默认镜像为 `ghcr.io/sfhgknsdfksdlf/agent-devbox:latest`，请确保服务器可以拉取该镜像。
- 网页界面只有一个端口（默认 6767）；`opencode serve` 默认只在容器内监听
  `127.0.0.1`，不对外暴露。
