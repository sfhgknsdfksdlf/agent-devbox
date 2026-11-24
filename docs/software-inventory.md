# Software inventory & ecosystem classification

What is installed in `agent-devbox-core` / `agent-devbox`, grouped by the
ecosystem it belongs to, plus what was **removed** and **added**.

## Base

| Item | Ecosystem | Notes |
|---|---|---|
| Debian 13 (trixie) + Node 24 | OS / Node runtime | base `node:24-trixie-slim` |

## AI agent cluster

| Software | Ecosystem | Notes |
|---|---|---|
| paseo (`@getpaseo/cli`) | Agent orchestration | daemon + bundled web UI, port 6767 |
| OpenCode (`opencode-ai@^1`) | AI coding agent | **latest V1**; V2 (`@opencode/cli`) is intentionally NOT installed |
| omo (`oh-my-openagent`) | OpenCode plugin | agents/categories mapping, `@latest` |
| Cloudflare `wrangler` + `create-cloudflare` | CF Workers | `workerd`/`miniflare` come transitively |

### Extra agent CLIs — only in the DEFAULT image `agent-devbox`

| CLI | Ecosystem |
|---|---|
| Claude Code (`@anthropic-ai/claude-code`) | Anthropic agent |
| Codex CLI (`@openai/codex`) | OpenAI agent |
| Gemini CLI (`@google/gemini-cli`) | Google agent |
| Qwen Code (`@qwen-code/qwen-code`) | Alibaba/Qwen agent |
| Crush (`@charmland/crush`) | Charmbracelet TUI agent |
| GitHub Copilot CLI (`@github/copilot`) | GitHub agent |
| Pi (`@earendil-works/pi-coding-agent`) | Earendil agent |
| DeepSeek Harness (`@deepseek-ai/dsh`) | DeepSeek harness |
| Grok Build (`@xai-official/grok`) | xAI agent |
| zcode (`zcode-app-cli`) | Z.ai ZCode terminal client (community) |
| Aider (`aider-chat`, via `uv tool`, Python 3.12) | Python agent |

## MCP servers (11)

All 11 are globally available to OpenCode. Eight are managed in
`/etc/opencode/opencode.json` (applied last as the V1 global config);
`context7`, `grep_app` and `lsp` are injected by omo at runtime.

| MCP | Type | Source / launch | Notes |
|---|---|---|---|
| `memory` | local, resident | `mcp-memory-service` (PyPI) | one loopback HTTP service per UID; OpenCode plugin auto-captures |
| `websearch` | local stdio | `open-websearch` (npm global) | same key overrides omo's Exa-backed `websearch` |
| `tavily` | remote | `https://mcp.tavily.com/mcp/` | keyless (`X-Tavily-Access-Mode: keyless`); search/extract only, crawl/map/research need a key |
| `context7` | built-in | omo runtime | documentation lookup |
| `grep_app` | built-in | omo runtime | GitHub code search |
| `lsp` | built-in | omo runtime | LSP tools |
| `shadcn` | local stdio | `shadcn mcp` | runs in the project cwd |
| `wails3` | local stdio | `wails3 mcp` | build-time `@latest` |
| `playwright` | local stdio | `@playwright/mcp` | headless, isolated, `/usr/local/bin/chromium` |
| `deepwiki` | remote | `https://mcp.deepwiki.com/mcp` | no key; public repos only |
| `delve` | local stdio | `mcp-dap-server` | Delve DAP adapter, enabled by default |

### Managed config vs runtime injection

- `/etc/opencode/opencode.json` holds exactly the eight non-omo servers:
  `memory`, `websearch`, `tavily`, `shadcn`, `wails3`, `playwright`, `deepwiki`,
  `delve`.
- `context7`, `grep_app` and `lsp` are omo built-ins, injected at runtime, and
  must not appear in that file.
- The file has **no `plugin` key**: a managed `plugin` array would replace omo's
  own plugin array. The memory plugin is auto-discovered from
  `~/.config/opencode/plugins/memory-plugin.js`.

### Not installed

Sequential Thinking, OpenSpec, markitdown-mcp, OpenViking, Mem0, Serena, Chrome
DevTools MCP.

## Language toolchains

| Software | Ecosystem |
|---|---|
| build-essential, pkg-config, libssl-dev | native build (all) |
| Go + gopls + dlv + **wails3** + GTK/WebKit dev libs | Go / **Wails3 desktop** |
| Python 3 + pip + venv + dev + pipx + **uv** | Python |
| Node 24 + npm; **bun / pm2 / tsx / esbuild / vite** | Node / JS |

## Editors / LSP / code tools

`typescript`, `typescript-language-server`, `vscode-langservers-extracted`,
`yaml-language-server`, `basedpyright`, `@ast-grep/cli`, `@biomejs/biome`,
`clangd`, `ripgrep`, `fd-find`, `bat`, `fzf`, `jq`, `tree`, `git`, `openssh-client`.

## Browser / QA

Playwright + Chromium (+ system deps), CJK fonts (`fonts-noto-cjk`, `fonts-nanum`,
`fonts-noto-color-emoji`), `xvfb`, `xauth`, `imagemagick`, `lighthouse`.

## Debug / system

`gdb`, `lldb`, `strace`-free, `lsof`, `sqlite3`, `poppler-utils`, `tini`, `gosu`,
`tmux`, `vim`, `nano`, `htop`, `psmisc`, `file`, `rsync`, `patch`, `unzip`/`zip`/`xz`.

## REMOVED (to keep it lean)

| Removed | Why |
|---|---|
| `zoxide` | shell convenience only |
| `ffmpeg` | media only; large |
| `openjdk-17` + `maven` | Java not used |
| Rust toolchain (rustup/cargo/rust-analyzer/clippy/rustfmt) | large; not used |
| `strace`, `ltrace` | rarely needed |
| `redis-server` | no ruo-long service required |

## ADDED

| Added | Why |
|---|---|
| `tini`, `gosu`, `util-linux` | init + privilege drop + `flock`/`findmnt` |
| `git`, `openssh-client` | explicit (do not rely on transitive installs) |
| `wrangler`, `create-cloudflare` | Cloudflare Workers dev/test |
| the extra agent CLIs | the point of the `agent-devbox` variant |
