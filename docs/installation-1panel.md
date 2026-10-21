# 1Panel 安装

用 1Panel 的「本地应用」安装。和 Docker、WSL 两种方式用的是**同一个镜像**，只是换了个安装入口。

## 1. 解压

从 **[Releases 页面](https://github.com/sfhgknsdfksdlf/agent-devbox/releases)** 下载
**`agent-devbox-1panel-localapp.zip`** 并解压，会得到一个 `agent-devbox/` 目录。

## 2. 放到本地应用目录

把这个 `agent-devbox/` 目录整个放到：

```text
/opt/1panel/resource/apps/local/agent-devbox/
```

确保最终路径就是 `.../local/agent-devbox/`，里面直接是 `data.yml`、`logo.png`、`README.md`
和 `latest/`（不要再多套一层目录）。

## 3. 同步并安装

打开 1Panel 的 **应用商店**，点 **「同步本地应用」**，列表里就会出现 **Agent Devbox**。

点 **安装**，按需填写：

| 字段 | 说明 | 默认值 |
|---|---|---|
| **访问密码** | 环境变量 `PASEO_PASSWORD`，**必填**（不填后台服务会拒绝启动） | `change-me-please`（请务必改掉） |
| **网页端口** | 环境变量 `PANEL_APP_PORT_HTTP`，对外访问用的端口 | `6767` |
| **时区** | 环境变量 `TZ`，容器时区 | `Asia/Shanghai` |

装完用浏览器打开 `http://<服务器IP>:6767` 就能进网页界面。

## 4. 数据在哪

数据都写在应用实例目录下的 `data/`：

- `data/home/` → 容器里的 `/home/paseo`
- `data/project/` → 容器里的 `/workspace`

升级或重装应用不会动这两个目录；删应用前先备份 `data/`。
