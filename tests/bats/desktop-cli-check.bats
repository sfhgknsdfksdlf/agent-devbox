#!/usr/bin/env bats
# desktop-cli-check.sh: pins the READ-ONLY desktop/Paseo CLI diagnostics.
#
# The desktop app probes exactly ONE path ($HOME/.opencode/bin/opencode) and
# never consults PATH; the Paseo daemon resolves agents through PATH instead.
# Every case is isolated: a real temp home, fake CLIs in $TMP/bin, and an
# explicit AGENT_DEVBOX_DESKTOP_CLIS so the host's real CLIs cannot leak in.

setup() {
  TMP="$(mktemp -d)"
  export TMP
  export SCRIPT="$BATS_TEST_DIRNAME/../../scripts/desktop-cli-check.sh"
  export HOME_DIR="$TMP/home"
  export BINDIR="$TMP/bin"
  export PATH="$BINDIR:$PATH"
  mkdir -p "$HOME_DIR" "$BINDIR"
}

teardown() { rm -rf "$TMP"; }

# fake_opencode <home> <version>: an executable desktop-style shim.
fake_opencode() {
  local home_dir ver
  home_dir="$1"
  ver="$2"
  mkdir -p "$home_dir/.opencode/bin"
  printf '#!/bin/sh\necho "%s"\n' "$ver" > "$home_dir/.opencode/bin/opencode"
  chmod +x "$home_dir/.opencode/bin/opencode"
}

# fake_cli <path> <version>: a CLI that prints its version.
fake_cli() {
  printf '#!/bin/sh\necho "%s"\n' "$2" > "$1"
  chmod +x "$1"
}

@test "probe home with an executable shim: rc 0, resolved path and PASS" {
  fake_opencode "$HOME_DIR" "1.19.3"

  run env AGENT_DEVBOX_DESKTOP_CLIS="fakecli" "$SCRIPT" --home "$HOME_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME_DIR/.opencode/bin/opencode"* ]]
  [[ "$output" == *"结论: PASS"* ]]
}

@test "probe home without the shim: rc 1, missing path and the probe command" {
  run env AGENT_DEVBOX_DESKTOP_CLIS="fakecli" "$SCRIPT" --home "$HOME_DIR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$HOME_DIR/.opencode/bin/opencode"* ]]
  [[ "$output" == *"sh -lc"* ]]
  [[ "$output" == *"结论: FAIL"* ]]
}

@test "shim exists but is not executable: rc 1" {
  mkdir -p "$HOME_DIR/.opencode/bin"
  printf '#!/bin/sh\necho "1.19.3"\n' > "$HOME_DIR/.opencode/bin/opencode"
  chmod -x "$HOME_DIR/.opencode/bin/opencode"

  run env AGENT_DEVBOX_DESKTOP_CLIS="fakecli" "$SCRIPT" --home "$HOME_DIR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"未解析到 CLI"* ]]
}

@test "--expected-opencode-version: exact match rc 0, mismatch rc 1 with both versions" {
  fake_opencode "$HOME_DIR" "1.19.3"

  run env AGENT_DEVBOX_DESKTOP_CLIS="fakecli" "$SCRIPT" \
    --home "$HOME_DIR" --expected-opencode-version "1.19.3"
  [ "$status" -eq 0 ]

  run env AGENT_DEVBOX_DESKTOP_CLIS="fakecli" "$SCRIPT" \
    --home "$HOME_DIR" --expected-opencode-version "2.0.0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2.0.0"* ]]
  [[ "$output" == *"1.19.3"* ]]
  [[ "$output" == *"桌面版 2.0.0 / CLI 1.19.3"* ]]
}

@test "an absent optional CLI: rc 0 and the 未安装 hint" {
  fake_opencode "$HOME_DIR" "1.19.3"

  run env AGENT_DEVBOX_DESKTOP_CLIS="totallynotacli" "$SCRIPT" --home "$HOME_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"totallynotacli"* ]]
  [[ "$output" == *"未安装"* ]]
  [[ "$output" == *"结论: PASS"* ]]
}

@test "a CLI present only in ~/.local/bin: rc 0 plus a 警告 naming the path" {
  fake_opencode "$HOME_DIR" "1.19.3"
  mkdir -p "$HOME_DIR/.local/bin"
  fake_cli "$HOME_DIR/.local/bin/hiddencli" "9.9.9"

  run env AGENT_DEVBOX_DESKTOP_CLIS="hiddencli" "$SCRIPT" --home "$HOME_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"警告"* ]]
  [[ "$output" == *"$HOME_DIR/.local/bin/hiddencli"* ]]
}

@test "a CLI hidden in a second --also-home is still reported" {
  fake_opencode "$HOME_DIR" "1.19.3"
  OTHER="$TMP/other-home"
  mkdir -p "$OTHER/.local/bin"
  fake_cli "$OTHER/.local/bin/secondcli" "1.0.0"

  run env AGENT_DEVBOX_DESKTOP_CLIS="secondcli" "$SCRIPT" \
    --home "$HOME_DIR" --also-home "$OTHER"

  [ "$status" -eq 0 ]
  [[ "$output" == *"警告"* ]]
  [[ "$output" == *"$OTHER/.local/bin/secondcli"* ]]
  [[ "$output" == *"PASS（有警告"* ]]
}

@test "--also-home prints an existence line and never executes the planted CLI" {
  fake_opencode "$HOME_DIR" "1.19.3"
  OTHER="$TMP/other-home"
  mkdir -p "$OTHER/.opencode/bin"
  cat > "$OTHER/.opencode/bin/opencode" <<SH
#!/bin/sh
: > "$TMP/executed.marker"
echo "1.19.3"
SH
  chmod +x "$OTHER/.opencode/bin/opencode"

  run env AGENT_DEVBOX_DESKTOP_CLIS="fakecli" "$SCRIPT" \
    --home "$HOME_DIR" --also-home "$OTHER" --also-home "$TMP/absent-home"

  [ "$status" -eq 0 ]
  [[ "$output" == *"存在/可执行: $OTHER/.opencode/bin/opencode"* ]]
  [[ "$output" == *"缺失: $TMP/absent-home/.opencode/bin/opencode"* ]]
  [ ! -e "$TMP/executed.marker" ]
}

@test "a silent --version prints (无输出); opencode with no version fails" {
  fake_opencode "$HOME_DIR" "1.19.3"
  # A CLI that exits 0 without printing anything.
  printf '#!/bin/sh\nexit 0\n' > "$BINDIR/silentcli"
  chmod +x "$BINDIR/silentcli"

  run env AGENT_DEVBOX_DESKTOP_CLIS="silentcli" "$SCRIPT" --home "$HOME_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(无输出)"* ]]

  printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/.opencode/bin/opencode"
  chmod +x "$HOME_DIR/.opencode/bin/opencode"
  run env AGENT_DEVBOX_DESKTOP_CLIS="opencode" "$SCRIPT" --home "$HOME_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(无输出)"* ]]
}

@test "--home with no value: rc 2 (usage error)" {
  run env AGENT_DEVBOX_DESKTOP_CLIS="fakecli" "$SCRIPT" --home

  [ "$status" -eq 2 ]
  [[ "$output" == *"--home 缺少参数"* ]]
}
