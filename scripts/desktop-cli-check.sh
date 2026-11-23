#!/usr/bin/env bash
# =============================================================================
# desktop-cli-check.sh — READ-ONLY diagnostic for the OpenCode Desktop app (and
# the Paseo daemon) inside an agent-devbox distro.
#
# WHY THIS EXISTS (verified behaviour, do not "simplify"):
#   The OpenCode DESKTOP app does NOT search PATH for a CLI inside WSL. It runs
#   exactly ONE probe and then execs the absolute path it printed:
#     wsl.exe -d <distro> -- sh -lc \
#       'if [ -x "$HOME/.opencode/bin/opencode" ]; then printf "%s\n" "$HOME/.opencode/bin/opencode"; fi'
#   then runs `<path> serve ...`. It also requires `bash` and `curl` inside the
#   distro, and the first line of `opencode --version` must EQUAL the desktop
#   app's version. Empty stdout means "not installed" — the exit code is not
#   trusted.
#
#   The Paseo daemon is different: it resolves agent CLIs via `which -a <name>`
#   + `<path> --version`, so they must be on the daemon user's PATH (where
#   /usr/local/bin comes first). Section [3]/[4] cover that side.
#
# CROSS-ACCOUNT SAFETY (verified requirement, do not "simplify"):
#   Only the CURRENT account's home may be probed/EXECUTED. It is resolved with
#   `getent passwd "$EUID"` (field 6) + `realpath -m` (fallback `readlink -f`),
#   never from an unrelated `$HOME`. Every other --home / --also-home value is
#   EXISTENCE-ONLY: checking `DIR/.opencode/bin/opencode` with `-x` (and never
#   running anything inside it), because executing another user's CLI as this
#   user would be unsafe and proves nothing about this account's desktop setup.
#
# READ-ONLY: this script never creates, links, chmods or removes anything. It is
# safe to run at any time; every fix it suggests is printed, never executed.
#
# Exit: 0 = app-critical checks pass, 1 = app-critical failure OR the current
#       account home was not requested (limited run, not a pass), 2 = usage.
# =============================================================================
set -uo pipefail

# The WSL boot/login PATH can be minimal. /usr/local/bin is where the image
# ships every CLI and is first in the daemon's PATH, so probe the same view.
PATH="/usr/local/bin:$PATH"
export PATH

# The desktop app's one and only discovery command (executed with HOME=<home>).
# Single-quoted ON PURPOSE: $HOME must expand inside `sh -lc`, not in this shell.
# shellcheck disable=SC2016
PROBE_SCRIPT='if [ -x "$HOME/.opencode/bin/opencode" ]; then printf "%s\n" "$HOME/.opencode/bin/opencode"; fi'
CLI_LIST="${AGENT_DEVBOX_DESKTOP_CLIS:-opencode claude codex gemini qwen crush copilot pi dsh grok zcode aider}"
VERSION_TIMEOUT="${AGENT_DEVBOX_VERSION_TIMEOUT:-10}"

HOMES=()
ALSO_HOMES=()
EXISTENCE_HOMES=()
EXPECTED_VERSION=""
CURRENT_HOME=""
MISSING=()
probe_missing=0
missing_home=""
version_fail=0
deps_fail=0
warn=0
fail=0

usage() {
  cat <<'EOF'
用法: desktop-cli-check.sh [--home DIR] [--also-home DIR]... [--expected-opencode-version VER]

  --home DIR                       要探测的身份（默认：当前账户 HOME；可重复）
                                   仅当 DIR 解析后等于当前账户 HOME 时才真正执行探测；
                                   其他目录只检查存在性，绝不执行其中任何程序
  --also-home DIR                  只检查 DIR/.opencode/bin/opencode 是否存在（可重复，不执行）
  --expected-opencode-version V    桌面版版本；CLI 首行版本必须与之完全相等

当前账户 HOME 由 getent passwd $EUID（第 6 字段）+ realpath 解析，不使用 $HOME。
--home 全是其他账户目录时：只做存在性检查，结论为「未完整验证」，退出码 1（不代表故障）。

环境变量:
  AGENT_DEVBOX_DESKTOP_CLIS        要检查的 CLI 名称列表（空格分隔）
  AGENT_DEVBOX_VERSION_TIMEOUT     --version 的超时秒数（默认 10）
  AGENT_DEVBOX_DESKTOP_CURRENT_HOME 仅供测试：覆盖当前账户 HOME（生产不要设置）

退出码: 0 = 关键项通过 · 1 = 关键项失败/未完整验证 · 2 = 用法错误
EOF
}

# canonical_path <path>: realpath -m, then readlink -f, then the raw value.
canonical_path() {
  local path out
  path="$1"

  if command -v realpath >/dev/null 2>&1; then
    out="$(realpath -m -- "$path" 2>/dev/null)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  if command -v readlink >/dev/null 2>&1; then
    out="$(readlink -f -- "$path" 2>/dev/null)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  printf '%s\n' "$path"
}

# resolve_current_home(): field 6 of getent passwd "$EUID", canonicalized.
# The test-only override is the ONLY way to bypass getent; production never
# substitutes an unrelated $HOME when the account lookup fails.
resolve_current_home() {
  local override entry rest home
  override="${AGENT_DEVBOX_DESKTOP_CURRENT_HOME:-}"

  if [ -n "$override" ]; then
    canonical_path "$override"
    return 0
  fi

  if ! command -v getent >/dev/null 2>&1; then
    return 1
  fi

  if ! entry="$(getent passwd "$EUID" 2>/dev/null)"; then
    return 1
  fi
  if [ -z "$entry" ]; then
    return 1
  fi

  rest="$entry"
  rest="${rest#*:}"
  rest="${rest#*:}"
  rest="${rest#*:}"
  rest="${rest#*:}"
  rest="${rest#*:}"
  home="${rest%%:*}"
  if [ -z "$home" ]; then
    return 1
  fi

  canonical_path "$home"
}

# capture <cmd> [args...]: run with a timeout when available, stdout only.
# `timeout` is an optional tool, so guard it instead of assuming coreutils.
capture() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$VERSION_TIMEOUT" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

# probe_home <home> <expected-version>: the desktop app's exact probe + version.
# Defence-in-depth: this is the ONLY place that executes a CLI from a home, so
# it refuses anything that is not the resolved current-account home.
probe_home() {
  local home_dir expected out path ver ver_status
  home_dir="$1"
  expected="$2"

  if [ "$home_dir" != "$CURRENT_HOME" ]; then
    printf '  ✗ 拒绝在非当前账户 HOME 执行探测: %s\n' "$home_dir"
    return 1
  fi

  printf '\n[1] 当前账户 HOME 桌面版探测  HOME=%s\n' "$home_dir"
  printf "  探测命令（桌面版只用这一条，不查 PATH）:\n"
  printf "    wsl.exe -d <发行版> -- sh -lc '%s'\n" "$PROBE_SCRIPT"

  # Execute the probe verbatim, exactly as the app does (HOME overridden).
  out="$(capture env HOME="$home_dir" sh -lc "$PROBE_SCRIPT")"
  if [ -z "$out" ]; then
    printf '  ✗ 未解析到 CLI: %s（桌面版会认为“未安装”）\n' "$home_dir/.opencode/bin/opencode"
    probe_missing=1
    if [ -z "$missing_home" ]; then
      missing_home="$home_dir"
    fi
    return 1
  fi

  path="${out%%$'\n'*}"
  printf '  ✓ 解析到: %s\n' "$path"

  # Capture, then cut the FIRST line in-shell. Never pipe into `head`: under
  # pipefail that can die on SIGPIPE when the CLI writes more than one line.
  ver="$(capture env HOME="$home_dir" "$path" --version)"
  ver_status=$?
  if [ "$ver_status" -ne 0 ]; then
    printf '  ✗ 版本命令失败（退出码 %s）: %s --version\n' "$ver_status" "$path"
    version_fail=1
    return 1
  fi
  ver="${ver%%$'\n'*}"
  if [ -z "$ver" ]; then
    printf '  版本: (无输出)\n'
    version_fail=1
    return 1
  fi
  printf '  版本: %s\n' "$ver"

  if [ -n "$expected" ] && [ "$ver" != "$expected" ]; then
    printf '  ✗ 版本不匹配: 桌面版 %s / CLI %s\n' "$expected" "$ver"
    version_fail=1
    return 1
  fi
  return 0
}

# check_hard_deps(): bash/curl are required by the desktop app; git only by
# Claude Desktop's WSL session (warning, never app-critical).
check_hard_deps() {
  local tool path missing
  missing=0

  printf '\n[2] 桌面版硬性依赖\n'
  for tool in bash curl git; do
    path="$(command -v "$tool" 2>/dev/null)"
    if [ -n "$path" ]; then
      printf '  ✓ %-5s %s\n' "$tool" "$path"
      continue
    fi
    printf '  ✗ %-5s 缺失\n' "$tool"
    case "$tool" in
      bash|curl)
        missing=1
        ;;
      git)
        printf '  警告: 缺少 git，Claude Desktop 的 WSL 会话将不可用\n'
        ;;
    esac
  done

  if [ "$missing" -ne 0 ]; then
    return 1
  fi
  return 0
}

# check_path_clis(): resolve each configured CLI the way Paseo does (PATH).
# Absent names are recorded for the "installed somewhere invisible" section.
check_path_clis() {
  local -a clis
  local name path ver silent_opencode
  silent_opencode=0

  printf '\n[3] 已知 CLI（按 PATH 解析）\n'
  read -r -a clis <<< "$CLI_LIST"
  for name in "${clis[@]}"; do
    path="$(command -v "$name" 2>/dev/null)"
    if [ -z "$path" ]; then
      if [ "$name" = "opencode" ]; then
        printf '  %-8s 未安装（core 也应提供，缺失说明 PATH 或安装异常）\n' "$name"
      else
        printf '  %-8s 未安装（core 精简版不含；agents 变体提供）\n' "$name"
      fi
      MISSING+=("$name")
      continue
    fi

    ver="$(capture "$path" --version)"
    ver="${ver%%$'\n'*}"
    if [ -z "$ver" ]; then
      ver="(无输出)"
      if [ "$name" = "opencode" ]; then
        silent_opencode=1
      fi
    fi
    printf '  %-8s %s  %s\n' "$name" "$path" "$ver"
  done

  if [ "$silent_opencode" -ne 0 ]; then
    return 1
  fi
  return 0
}

# check_misplaced(): an installed-but-not-on-PATH CLI is invisible to Paseo and
# to a login shell. Report the path and PRINT a fix; never execute it.
check_misplaced() {
  local name found dir home_dir any
  any=0

  printf '\n[4] 可能装错位置（扫描每个 --home / --also-home，只看存在性）\n'
  for name in "${MISSING[@]}"; do
    for home_dir in "${HOMES[@]}" "${ALSO_HOMES[@]}"; do
      for dir in ".local/bin" ".npm-global/bin" ".bun/bin" ".local/share/pnpm"; do
        found="$home_dir/$dir/$name"
        if [ -x "$found" ]; then
          any=1
          warn=1
          printf '  警告: %s 不在 PATH 上，PATH 消费者（Paseo 守护进程 / 登录 shell）看不到它\n' "$found"
          printf '    修复提示（仅打印，不会执行）: ln -sfn %s /usr/local/bin/%s\n' "$found" "$name"
        fi
      done
    done
  done

  if [ "$any" -eq 0 ]; then
    printf '  ✓ 未发现「已安装但不在 PATH 上」的 CLI\n'
  fi
}

# check_existence_homes(): existence-only for foreign --home and every
# --also-home. Nothing inside another home is ever executed.
check_existence_homes() {
  local home_dir path

  printf '\n[5] 其他 HOME（只查存在性，不执行；外来 --home / --also-home）\n'
  if [ "${#EXISTENCE_HOMES[@]}" -eq 0 ]; then
    printf '  （未指定）\n'
    return 0
  fi

  for home_dir in "${EXISTENCE_HOMES[@]}"; do
    path="$home_dir/.opencode/bin/opencode"
    if [ -x "$path" ]; then
      printf '  存在/可执行: %s（仅存在性，未执行）\n' "$path"
    else
      printf '  缺失: %s（不存在或不可执行；仅存在性检查，未执行）\n' "$path"
    fi
  done
}

main() {
  local home_dir
  local -a probe_homes=()
  local -a foreign_homes=()
  local limited=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home)
        if [ "$#" -lt 2 ]; then
          printf '错误: --home 缺少参数\n' >&2
          exit 2
        fi
        HOMES+=("$(canonical_path "$2")")
        shift 2
        ;;
      --also-home)
        if [ "$#" -lt 2 ]; then
          printf '错误: --also-home 缺少参数\n' >&2
          exit 2
        fi
        ALSO_HOMES+=("$(canonical_path "$2")")
        shift 2
        ;;
      --expected-opencode-version)
        if [ "$#" -lt 2 ]; then
          printf '错误: --expected-opencode-version 缺少参数\n' >&2
          exit 2
        fi
        EXPECTED_VERSION="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf '错误: 未知参数 %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if ! CURRENT_HOME="$(resolve_current_home)"; then
    printf '错误: 无法解析当前账户（EUID=%s）的主目录；不会改用环境变量 HOME 猜测。请检查 getent passwd（或测试用 AGENT_DEVBOX_DESKTOP_CURRENT_HOME）。\n' "$EUID" >&2
    exit 1
  fi

  # Default identity: the current account home. A requested --home is probed
  # ONLY when it canonicalizes to that same path; everything else is foreign.
  if [ "${#HOMES[@]}" -eq 0 ]; then
    HOMES=("$CURRENT_HOME")
  fi
  for home_dir in "${HOMES[@]}"; do
    if [ "$home_dir" = "$CURRENT_HOME" ]; then
      probe_homes+=("$home_dir")
    else
      foreign_homes+=("$home_dir")
    fi
  done
  if [ "${#probe_homes[@]}" -eq 0 ]; then
    limited=1
  fi
  EXISTENCE_HOMES=("${foreign_homes[@]}" "${ALSO_HOMES[@]}")

  printf '== agent-devbox 桌面版 CLI 自查 ==\n'
  printf '身份: %s  EUID=%s\n' "$(id -un 2>/dev/null || printf '%s' "$EUID")" "$EUID"
  printf '当前账户 HOME: %s（getent/realpath）\n' "$CURRENT_HOME"

  if [ "${#probe_homes[@]}" -eq 0 ]; then
    printf '\n[1] 当前账户 HOME 桌面版探测\n'
    printf '  （当前账户 HOME=%s 未被 --home 请求，跳过探测；其他 --home 只做存在性检查）\n' "$CURRENT_HOME"
  else
    for home_dir in "${probe_homes[@]}"; do
      if ! probe_home "$home_dir" "$EXPECTED_VERSION"; then
        fail=1
      fi
    done
  fi

  if ! check_hard_deps; then
    deps_fail=1
    fail=1
  fi
  if ! check_path_clis; then
    fail=1
  fi

  check_misplaced
  check_existence_homes

  printf '\n[6] 结论\n'
  if [ "$fail" -eq 0 ] && [ "$limited" -ne 0 ]; then
    printf '  结论: 未完整验证（当前账户 HOME=%s 未被 --home 请求）\n' "$CURRENT_HOME"
    printf '  只对请求的其他账户目录做了存在性检查（未执行其中任何 CLI），不能证明桌面版可用。\n'
    printf '  需要完整结论: 请加 --home %s\n' "$CURRENT_HOME"
    exit 1
  fi
  if [ "$fail" -eq 0 ]; then
    if [ "$warn" -ne 0 ]; then
      printf '  结论: PASS（有警告，见 [4]：这些 CLI 桌面版看不到）\n'
    else
      printf '  结论: PASS\n'
    fi
    exit 0
  fi

  printf '  结论: FAIL\n'
  printf '  修复（手动，脚本不会执行）:\n'
  if [ "$probe_missing" -ne 0 ]; then
    printf '    - 探测路径缺失（%s）：\n' "${missing_home:-$CURRENT_HOME}"
    printf '      mkdir -p "%s/.opencode/bin" && ln -sfn /usr/local/bin/opencode "%s/.opencode/bin/opencode"\n' "${missing_home:-$CURRENT_HOME}" "${missing_home:-$CURRENT_HOME}"
  fi
  if [ "$version_fail" -ne 0 ]; then
    printf '    - 版本不一致/无法取版本：把桌面版升级到与 CLI 相同版本，或用桌面版的「更新 OpenCode」让它自己装一份\n'
  fi
  if [ "$deps_fail" -ne 0 ]; then
    printf '    - 缺少运行依赖：发行版内必须有 bash 与 curl\n'
  fi
  if [ "$limited" -ne 0 ]; then
    printf '  注意: 当前账户 HOME=%s 未被 --home 请求，本次未做桌面版探测。\n' "$CURRENT_HOME"
  fi
  printf '  如果刚添加/重装过发行版仍不生效: 完全退出桌面版（含托盘）后重开，再添加发行版\n'
  exit 1
}

main "$@"
