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
| **访问密码** | 环境变量 `PASEO_PASSWORD`，**必填**；请自行设置强密码，空值或旧版公开默认值都会被拒绝启动 | 无（必须填写） |
| **网页端口** | 环境变量 `PANEL_APP_PORT_HTTP`，对外访问用的端口 | `6767` |
| **时区** | 环境变量 `TZ`，容器时区 | `Asia/Shanghai` |

> **从旧版本升级**：旧版表单曾预填公开默认密码 `change-me-please`。如果现有实例仍在
> 使用它，请先在 1Panel 中把访问密码改成你自己的强密码，再更新镜像；新版运行期会拒绝
> 空值和该旧默认值。

装完用浏览器打开 `http://<服务器IP>:6767` 就能进网页界面。

## 4. 数据在哪

数据都写在应用实例目录下的 `data/`，容器里对应四个挂载：

- `data/` → `/run/agent-devbox/data`（只读，身份基准）
- `data/home/` → 容器里的 `/home`
- `data/root/` → 容器里的 `/root`
- `data/project/` → 容器里的 `/workspace`

1Panel 的 compose 用的是短语法，启动时 Docker 会自动补建缺失的 `data/...` 目录。真正的保护是容器的
preflight：它在任何写入或启动服务之前，用 `stat -c '%d:%i'` 比对 `/run/agent-devbox/data/{home,root,project}`
与三个目标；不一致就 fail closed。首启还会把 `/home/paseo` 设为 1000:1000、`/root` 设为 0:0（0700），
只补缺失的 skeleton。升级或重装应用不会动这些目录；删应用前先备份 `data/`。
