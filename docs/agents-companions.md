# Extra agent CLIs & their usual companions

The default image `agent-devbox` adds these on top of `agent-devbox-core`.

| CLI | Install | Command | Runtime | Usual companions |
|---|---|---|---|---|
| Claude Code | `@anthropic-ai/claude-code` | `claude` | Node + native binary | git, ripgrep (bundled), `gh` |
| Codex CLI | `@openai/codex` | `codex` | Node | git, ripgrep, `gh` |
| Gemini CLI | `@google/gemini-cli` | `gemini` | Node >=20 | git, Chrome (web tools) |
| Qwen Code | `@qwen-code/qwen-code` | `qwen` | Node | git, ripgrep |
| Crush | `@charmland/crush` | `crush` | Node | git |
| GitHub Copilot CLI | `@github/copilot` | `copilot` | Node | git, `gh` auth |
| Pi | `@earendil-works/pi-coding-agent` | `pi` | Node >=22.19 | git, ripgrep |
| DeepSeek Harness | `@deepseek-ai/dsh` | `dsh` | Node ^22.19 \|\| >=24 | **pnpm** (plugins), git |
| Grok Build | `@xai-official/grok` | `grok` | native binary | git, `config.toml`, API key |
| zcode | `zcode-app-cli` | `zcode` | Node >=22.19 | git (community client of Z.ai ZCode) |
| Aider | `pipx install aider-chat` | `aider` | Python | git, OpenAI/Anthropic keys |

Common baseline already present: `git`, `ripgrep`, `gh` (install via apt or the
GitHub CLI), Node 22.23 (satisfies the >=22.19 requirement), `patch`, `rsync`.

## Notes / caveats

- **Grok Build** is a native (Rust) binary distributed by `@xai-official/grok` or
  the `https://x.ai/cli/install.sh` installer. Uses `~/.grok/config.toml`.
- **zcode** is the *community* terminal client (`zcode-app-cli`); the official
  ZCode is build-from-source. Treat the community package's trust accordingly.
- **DeepSeek Harness** is a public preview (`@deepseek-ai/dsh`); the CLI needs
  `pnpm` at runtime for `dsh plugin` operations.
- Credentials live under the user's home (`~/.claude`, `~/.codex`, `~/.gemini`,
  `~/.grok`, etc.) and therefore persist via the mounted/writable home.

## Other popular CLIs (not included)

Aider (older Python), Crush, Qwen Code, Copilot CLI are included. Not included:
Amp (`@ampcode/cli`), Continue CLI (`@continuedev/cli`), Block Goose, Amazon Q
Developer CLI, Factory Droid, Codebuff. VS Code extensions (Cline, Roo Code,
Kilo Code) are not CLIs.
