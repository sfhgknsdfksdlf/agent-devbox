# 桌面 App 怎么发现镜像里的 CLI

一句话结论：本次核查的桌面客户端里，**只有 OpenCode 桌面版要求固定路径**
（`$HOME/.opencode/bin/opencode`，且完全不查 PATH）；Paseo 桌面版只认 paseo 守护进程的 PATH；
Claude Code 桌面版的 WSL 会话、Claude 的 VS Code/Cursor 扩展、Windows 的 Codex app 都自带
或自己安装 CLI；其余 agent CLI 没有会去 WSL 里找它们的桌面客户端，PATH 是唯一要求。

本文只回答「谁看得见谁」。`ensure_opencode_shim` 的来龙去脉和完整排查过程见
[docs/qa.md](qa.md) 的「OpenCode 桌面版添加 WSL 服务器提示未安装 OpenCode？」一节；一条命令的
自查工具是 [`scripts/desktop-cli-check.sh`](../scripts/desktop-cli-check.sh)。

## 对照表

| 桌面客户端 | 在哪执行 / 怎么发现 | 固定路径要求 | core 变体 | agents 变体 | 备注 |
|---|---|---|---|---|---|
| OpenCode Desktop（Windows 1.19.3） | Windows 侧用一条 `wsl.exe -d <发行版> -- sh -lc '<探针>'` 找 CLI，再 exec 它打印的绝对路径起 sidecar；不查 PATH | **有**：`$HOME/.opencode/bin/opencode` 可执行、版本首行等于桌面版、发行版内有 `bash` 与 `curl` | 满足，开机 `ensure_opencode_shim` 建链接 | 满足，同一个链接 | 只探测 `opencode`；探测结果按发行版缓存在内存 |
| Paseo Desktop | 本次核查的 0.10.3 asar 里没有 WSL 相关代码；连 paseo 守护进程，由守护进程自己用 `which -a <name>` + `<path> --version` 解析 | 无固定路径；必须在**守护进程用户的 PATH** 上（`paseo-boot.sh` 钉死的前缀里含 `/usr/local/bin`） | `opencode` + `paseo` | 全部 agent CLI | 只装到 `~/.local/bin` 之类的目录就看不见 |
| Claude Code Desktop（WSL 会话） | 会话在发行版**内部**运行，官方文档的说法是「Claude sets up inside it」，即它自己在发行版里装 CLI | 无；要求 WSL2 + 已安装的发行版 + 发行版内有 `git` | 满足（`git`/`bash`/`curl` 都在 core） | 满足 | 官方文档说它自己安装；本次未验证它是否会复用镜像里的 `claude` |
| Claude Code 的 VS Code / Cursor 扩展 | 扩展「bundles its own copy of the CLI」，跑在编辑器一侧 | 无 | 不涉及 | 不涉及 | 与镜像内容无关 |
| OpenAI Codex（app + CLI） | Windows app 自带 `codex.exe`；CLI 官方安装文档把 Windows 支持写成「Windows 11 via WSL2」，即在发行版里跑 `codex` | 无 | 不提供 `codex` | `/usr/local/bin/codex` | 本次核查范围内，没有 Windows 侧发现 WSL `codex` 的逻辑 |
| VS Code Remote-WSL | 在发行版里装自己的 server，再用登录 shell 跑工具 | 无 | 满足 | 满足 | 不按固定路径找这些 CLI |
| 其它 CLI（gemini/qwen/crush/copilot/pi/dsh/grok/zcode/aider） | 终端里直接运行 | 无 | 未提供（只有语言工具链） | 全部在 `/usr/local/bin` | 没有发现 WSL CLI 的桌面客户端，PATH 是唯一要求 |

## OpenCode 桌面版的「三道门」

桌面版只用一条命令找 CLI，这条命令就是契约，单引号和 `$HOME` 都不能改：

```sh
wsl.exe -d <发行版> -- sh -lc 'if [ -x "$HOME/.opencode/bin/opencode" ]; then printf "%s\n" "$HOME/.opencode/bin/opencode"; fi'
```

拿到路径后，它执行
`<path> --print-logs --log-level WARN serve --hostname 0.0.0.0 --port <随机端口>`，
用 Basic 认证（用户名固定 `opencode`）轮询 `/api/health`。以下三关必须同时通过。

| 关卡 | 桌面版检查什么 | 不满足时的后果 |
|---|---|---|
| 1. 路径与可执行位 | 探针里的 `[ -x "$HOME/.opencode/bin/opencode" ]`，输出为空就当作没装 | 列表里显示「未安装 OpenCode」，sidecar 起不来时报「{{distro}} 中未安装 OpenCode」，按钮变成「安装 OpenCode」 |
| 2. 版本相等 | `<path> --version` 的**第一行**与桌面版自身版本完全相等（本次是 `1.19.3`） | 按钮变成「更新 OpenCode」，点击会装桌面版自己那一份 |
| 3. 运行依赖 | 发行版内存在 `bash` 与 `curl`；WSL 版本必须是 2，桌面版这次探测的超时是 20 秒 | 表现为缺少 `bash`、`curl`：探针的 `sh -lc` 或安装器跑不起来，该发行版用不了 OpenCode（本次没有构造缺依赖的场景，只按代码里的硬依赖记录） |

第 2 关是"相等"不是"大于等于"：CLI 比桌面版新也算不匹配。第 3 关里 WSL1 会被直接拒绝。

`desktop-cli-check.sh` 只检查路径、版本和 bash/curl/git，**不判定 WSL 版本**（那是发行版属性，用 `wsl -l -v` 看）；它自己的 `--version` 超时默认 10 秒，可用 `AGENT_DEVBOX_VERSION_TIMEOUT` 调整。

## 为什么"明明改了还是提示未安装"

因为**探测结果只写一次内存**。添加服务器的界面把每个发行版的结果存在 `opencodeChecks[distro]`
里，填过一次就不再刷新；`refreshOpencodeChecks()` 只遍历**已经添加为服务器**的发行版。一个还
没被成功添加的发行版，在本次 App 会话里永远沿用第一次的结果。

最容易撞上的时间线，就是升级或重装的时候：

1. Windows 安装器执行 `wsl --unregister`，发行版暂时消失；
2. 桌面版正好在这时探测该发行版，探针失败（没有发行版，或没有 CLI），结果被缓存为"未安装"；
3. 几分钟后 rootfs 重新导入完成，`ensure_opencode_shim` 也把链接建好了；
4. 桌面版仍拿着第 2 步的内存结果，继续显示「未安装 OpenCode」，直到整个 App 退出重开。

界面上看到的两条固定文案是：「未安装 OpenCode」（列表 chip）和「{{distro}} 中未安装 OpenCode」
（sidecar 启动错误）。此时点「安装 OpenCode」或「更新 OpenCode」，桌面版会在发行版里执行

```sh
curl -fsSL https://opencode.ai/install | bash -s -- --version <桌面版版本>
```

装出来的是一份约 180 MB 的真实二进制，落在数据盘的 `~/.opencode/bin/opencode`。之后的开机脚本
看到它是可执行文件，会原样保留（日志写「已有可执行文件，保持不变」），这是设计如此：桌面版自己
装的 CLI 不覆盖。

## 自查与恢复（4 步）

在 PowerShell 里按顺序做，前三步都不会写文件（第 1 步会启动发行版并跑一次开机脚本；第 2、3 步会
执行 CLI 的 `--version`）。发行版名按实际变体替换，下面用 `agent-devbox-core`。

1. 确认发行版能起来：

```powershell
wsl -d agent-devbox-core -u root -e true
```

2. 原样执行桌面版那条探针，并单独看版本首行。期望输出绝对路径 `/root/.opencode/bin/opencode`，
   版本期望与桌面版相同：

```powershell
wsl -d agent-devbox-core -u root -- sh -lc 'if [ -x "$HOME/.opencode/bin/opencode" ]; then printf "%s\n" "$HOME/.opencode/bin/opencode"; fi'
wsl -d agent-devbox-core -u root -e /root/.opencode/bin/opencode --version
```

3. 一条命令跑完整自查（脚本自身不写盘；退出码 0 = 通过，1 = 关键项失败，2 = 用法错误）。它会把探针、
   版本、`bash`/`curl`/`git`、以及 PATH 上的每个 CLI 都过一遍，并提示"装了但不在 PATH 上"：

```powershell
wsl -d agent-devbox-core -u root -e desktop-cli-check.sh --home /root --also-home /home/paseo --expected-opencode-version 1.19.3   # 换成你的桌面版版本
```

4. 完全退出桌面版（包括托盘图标，不是关窗口），重新打开，再「添加」该发行版。之前从未添加成功
   过的，这里是**添加**而不是重新添加；缓存只活在进程里，退出就清空。

开机日志在 `/var/log/agent-devbox-boot.log`，搜 `桌面版` 就能看到每个 home 的处理结果（补执行位那条
不含「桌面版」，要搜 `补充可执行位`），四种形态：
`桌面版 OpenCode 探测路径已就绪：<path> -> <target>`（软链）、
`桌面版 OpenCode 探测路径已就绪（已有可执行文件，保持不变）：<path>`（真实文件）、
`已创建桌面版 OpenCode 探测链接：...`（本次新建）、`已为 ... 补充可执行位`（修复权限）。

## 装错位置的清单

Paseo 守护进程的 PATH 被 `scripts/paseo-boot.sh` 钉死为
`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin...`；登录 shell 则通过
`/etc/profile.d/agent-devbox.sh` 引入 `agent-env.sh`，把 `/usr/local/bin` 前置。四个常见的
per-user 目录不在这两条路径里：

| 目录 | 谁看得见 | 为什么不行 |
|---|---|---|
| `~/.local/bin` | 只有你自己显式把 PATH 加进去的 shell | 守护进程 PATH 不含它，登录 shell 也不保证前置它 |
| `~/.npm-global/bin` | 同上 | 只有配置了 npm prefix 并加进 PATH 的 shell |
| `~/.bun/bin` | 同上 | bun 安装器的默认落点，不在上述两条 PATH 上 |
| `~/.local/share/pnpm` | 同上 | pnpm 的全局 bin 目录，不在上述两条 PATH 上 |

结果就是"命令在终端里能跑，Paseo 里说没装"。修法只有两个：装到 `/usr/local/bin`（镜像里所有
CLI 都在这儿，直接可见），或者把该目录真正加到 PATH 上。例外只有一个：
`~/.opencode/bin/opencode` **必须**在那儿，因为 OpenCode 桌面版只认这个固定路径，这是我们主动
建的链接，不是装错位置。

## 已知时间炸弹

镜像通过 `opencode-ai@^1` 随 CI 自动升级，桌面版版本却是固定的。两者一旦不再相等，探针照样
通过，第 2 关版本校验会失败，界面从「安装」变成「更新 OpenCode」；点下去就会在数据盘上装一份
约 180 MB 的桌面版专属二进制，并从此绕过镜像里 npm 装的那份。

两个处理办法，二选一：

- 保持同一个 1.x：升级镜像后同步升级桌面版，让 `opencode --version` 与 App 版本重新相等；
- 让桌面版自己装：接受那份 180 MB 和数据盘占用，开机脚本会原样保留，功能正常，只是 CLI 不再
  由镜像更新。

## 证据与范围

桌面版的行为不是猜的：本次在版本 `1.19.3` 的已安装应用包（`C:\Users\<user>\AppData\Local\Programs\@opencode-aidesktop`）
里读了 main 的 `resolveWslOpencode()` 与 renderer 的缓存逻辑，探针、exec 参数、三道门、
`opencodeChecks[distro]`、安装按钮用的命令都来自那里。Claude 的结论来自官方文档
`code.claude.com/docs/en/desktop-wsl`（WSL 会话自行安装）与扩展自带 CLI 的说明；Codex 的结论
来自官方安装文档（Windows 11 via WSL2）和 `openai/codex` 源码（除 Linux sandbox 测试外不 spawn
`wsl.exe`，Windows app 自带 `codex.exe`）。

本环境是 Linux，**没有在 Windows 侧执行任何东西**；上表里"没有发现逻辑"这类否定结论，范围限于
本次核查的 OpenCode 桌面版 1.19.3 与当前版本的 Paseo / Claude / Codex / VS Code。桌面版后续
如果改了探测方式，以 `desktop-cli-check.sh` 的实际输出为准。
