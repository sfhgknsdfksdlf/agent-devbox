# syntax=docker/dockerfile:1.7
# =============================================================================
# agent-devbox-core — paseo (daemon + bundled Web UI) + OpenCode (latest V1) +
#                     omo (oh-my-openagent) + a broad dev/test toolchain.
#
# Base: node:24-trixie-slim  (Debian 13 "trixie", Node 24.x)
# Node 24 is REQUIRED (>=24.9.0): the derived Dockerfile.agents layer installs
# @deepseek-ai/dsh, whose current releases declare that engine floor.
# Dual-mode from ONE image:
#   * Docker (VPS):      IS_DOCKER=true  -> docker-entrypoint.sh (folders bind-mounted)
#   * WSL2 distro:       IS_DOCKER unset -> wsl-boot.sh (VHDX data disk persisted)
#
# Mode detection: `ENV IS_DOCKER=true` is baked here. `docker export` does NOT
# carry image ENV into the exported rootfs, so a WSL distro imported from the
# rootfs naturally has IS_DOCKER unset and falls through to the WSL branch.
#
# Persistence (WSL): the Windows installer creates+attaches a 32G dynamic VHDX;
# wsl-boot.sh mounts it and binds /home + /root + /workspace onto it, verifying
# the disk identity (findmnt/UUID) BEFORE seeding or starting anything.
#
# User model: interactive shell user = root; the paseo daemon runs as the
# non-root `paseo` user (uid/gid 1000), mirroring the official image.
#
# NOTE: upstream versions are intentionally NOT all pinned (OpenCode = latest
# V1 via `opencode-ai@^1`, omo = `oh-my-openagent@latest`) so a rebuild picks up
# the newest, while `versions.json` + a CI diff-gate records what was resolved.
# =============================================================================
# The base is pinned by its OCI *index* digest (multi-arch). Keep the readable
# tag alongside the digest so the provenance is obvious and updates stay reviewable.
FROM node:24-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0

ARG PLAYWRIGHT_VERSION=1.64.1
ARG GO_VERSION=1.27.2
ARG UV_VERSION=0.13.9

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    CHROME_PATH=/usr/local/bin/chromium \
    PASEO_HOME=/home/paseo/.paseo \
    PASEO_LISTEN=0.0.0.0:6767 \
    PASEO_WEB_UI_ENABLED=true \
    PASEO_LOG_FORMAT=json \
    PASEO_LOG_LEVEL=info \
    GOROOT=/usr/local/go \
    IS_DOCKER=true \
    PATH=/usr/local/go/bin:/usr/local/bin:$PATH
# HOME is deliberately NOT set globally: the WSL root shell must keep HOME=/root.
# paseo-boot.sh exports HOME=/home/paseo for the daemon only.

# Use bash with pipefail so any RUN pipeline fails fast (satisfies hadolint DL4006).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# -----------------------------------------------------------------------------
# L0) verified third-party asset policy (P1-1).
#     config/image-assets.sha256 is the only source of
#     (version, filename, arch) -> sha256, and every tool downloaded below is
#     verified with scripts/image-assets.sh BEFORE it is extracted/installed.
#     The helper lives under scripts/ because .dockerignore keeps .github/ out
#     of the build context.
# -----------------------------------------------------------------------------
COPY scripts/image-assets.sh /usr/local/bin/image-assets
COPY config/image-assets.sha256 /usr/local/share/agent-devbox/image-assets.sha256
RUN set -eux; \
    chmod 0755 /usr/local/bin/image-assets; \
    image-assets verify-manifest /usr/local/share/agent-devbox/image-assets.sha256

# -----------------------------------------------------------------------------
# L1) base CLI, init helpers, build toolchain, python, VCS
#     git/openssh-client are installed EXPLICITLY (do not rely on transitive deps).
#     e2fsprogs (mkfs.ext4) is REQUIRED by scripts/datadisk-init.sh to format the
#     WSL data disk; util-linux does NOT pull it in under --no-install-recommends.
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential pkg-config libssl-dev \
      ripgrep fd-find bat fzf jq tree \
      unzip zip xz-utils file rsync patch \
      less tmux vim nano \
      wget curl gnupg ca-certificates \
      procps psmisc htop util-linux e2fsprogs \
      sqlite3 tini gosu \
      git openssh-client \
      python3 python3-full python3-pip python3-venv python3-dev pipx; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    ln -sf /usr/bin/batcat /usr/local/bin/bat; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# L1b) repo/dev QA tooling: the suite this repo runs itself (bats/shellcheck),
#      CI triage (gh), man pages, and general network/forensics CLIs.
#      `marksman` has no Debian package -> a fixed-tag GitHub release binary,
#      arch-mapped and verified before it is installed.
#      It is a .NET single-file binary: without libicu76 it aborts with
#      "Couldn't find a valid ICU package" (exit 139), so the runtime is NOT
#      optional here.
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bats shellcheck gh man-db manpages libicu76 \
      bind9-dnsutils netcat-openbsd ethtool sysstat bridge-utils iproute2 \
      iptables nftables zstd parallel; \
    rm -rf /var/lib/apt/lists/*; \
    arch="$(dpkg --print-architecture)"; \
    marksman_asset="$(image-assets asset-name marksman "$arch")"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
      -o "/tmp/${marksman_asset}" \
      "https://github.com/artempyanykh/marksman/releases/download/2026-02-08/${marksman_asset}"; \
    image-assets verify-file \
      /usr/local/share/agent-devbox/image-assets.sha256 \
      2026-02-08 "$marksman_asset" "$arch" "/tmp/${marksman_asset}"; \
    install -m 0755 "/tmp/${marksman_asset}" /usr/local/bin/marksman; \
    rm -f "/tmp/${marksman_asset}"; \
    marksman --version

# -----------------------------------------------------------------------------
# L2) Playwright Chromium system deps
# -----------------------------------------------------------------------------
RUN set -eux; \
    npx -y playwright@${PLAYWRIGHT_VERSION} install-deps chromium; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# L3) CJK fonts + headed/screenshot + pixel-diff deps (visual-qa)
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      fonts-noto-cjk fonts-nanum fonts-noto-color-emoji fonts-liberation \
      xvfb xauth imagemagick; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# L4) Playwright Chromium body -> /ms-playwright (outside mounts) + stable symlinks
# -----------------------------------------------------------------------------
RUN set -eux; \
    npx -y playwright@${PLAYWRIGHT_VERSION} install chromium; \
    chown -R root:root /ms-playwright; \
    chmod -R a+rX,go-w /ms-playwright; \
    chrome="$(find /ms-playwright -type f -name chrome | head -n1 || true)"; \
    if [ -n "$chrome" ]; then ln -sf "$chrome" /usr/local/bin/chromium; ln -sf "$chrome" /usr/local/bin/chromium-browser; fi; \
    find /ms-playwright -maxdepth 3 -type f \( -name chrome -o -name headless_shell \) | sed 's/^/  browser: /'; \
    npm cache clean --force

# -----------------------------------------------------------------------------
# L5) Node global dev tools + language servers
# -----------------------------------------------------------------------------
RUN set -eux; \
    npm install -g \
      typescript \
      typescript-language-server \
      vscode-langservers-extracted \
      yaml-language-server \
      basedpyright \
      @ast-grep/cli \
      @biomejs/biome \
      lighthouse \
      playwright@${PLAYWRIGHT_VERSION}

# -----------------------------------------------------------------------------
# L6) Python tooling: uv + uvx from the pinned release archive.
#     The upstream curl-pipe-to-shell installer always takes the current release
#     and cannot be byte-verified, so it is deliberately unused.
# -----------------------------------------------------------------------------
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    uv_asset="$(image-assets asset-name uv "$arch")"; \
    uv_dir="${uv_asset%.tar.gz}"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
      -o "/tmp/${uv_asset}" \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${uv_asset}"; \
    image-assets verify-file \
      /usr/local/share/agent-devbox/image-assets.sha256 \
      "$UV_VERSION" "$uv_asset" "$arch" "/tmp/${uv_asset}"; \
    tar -C /tmp -xzf "/tmp/${uv_asset}"; \
    install -m 0755 "/tmp/${uv_dir}/uv" /usr/local/bin/uv; \
    install -m 0755 "/tmp/${uv_dir}/uvx" /usr/local/bin/uvx; \
    rm -rf "/tmp/${uv_asset}" "/tmp/${uv_dir}"; \
    uv --version; \
    uvx --version

# -----------------------------------------------------------------------------
# L7) Debuggers (gdb/lldb). ptrace needs --cap-add=SYS_PTRACE in Docker.
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gdb lldb; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# L8) Go toolchain (system-wide) ; per-user GOPATH/GOCACHE come from agent-env.sh
#     Arch comes from the container itself (dpkg), not BuildKit's TARGETARCH ARG,
#     whose default stuck at amd64 and broke the arm64 build.
#     The tarball is verified against config/image-assets.sha256 before extraction.
#     GOSUMDB must stay at the Go default (sum.golang.org): module checksum
#     verification is a supply-chain control, so the build fails if it is off.
# -----------------------------------------------------------------------------
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    go_arch="$(image-assets asset-name go "$arch")"; \
    go_asset="go${GO_VERSION}.linux-${go_arch}.tar.gz"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
      -o "/tmp/${go_asset}" \
      "https://go.dev/dl/${go_asset}"; \
    image-assets verify-file \
      /usr/local/share/agent-devbox/image-assets.sha256 \
      "$GO_VERSION" "$go_asset" "$arch" "/tmp/${go_asset}"; \
    tar -C /usr/local -xzf "/tmp/${go_asset}"; \
    rm -f "/tmp/${go_asset}"; \
    ln -sf /usr/local/go/bin/go /usr/local/bin/go; \
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt; \
    go version; \
    sumdb="$(go env GOSUMDB)"; \
    echo "GOSUMDB=${sumdb}"; \
    if [ "$sumdb" = "off" ]; then \
      echo "GOSUMDB must not be off (module checksum verification is required)" >&2; \
      exit 1; \
    fi

# L8b) Wails v3 desktop build libs + C/C++ LSP
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libgtk-3-dev libgtk-4-dev libwebkit2gtk-4.1-dev libwebkitgtk-6.0-dev \
      libayatana-appindicator3-dev clangd; \
    rm -rf /var/lib/apt/lists/*

# L8c) Go tooling installed system-wide (build-time, root)
RUN set -eux; \
    GOBIN=/usr/local/bin go install golang.org/x/tools/gopls@latest; \
    GOBIN=/usr/local/bin go install github.com/go-delve/delve/cmd/dlv@latest; \
    GOBIN=/usr/local/bin go install github.com/wailsapp/wails/v3/cmd/wails3@latest; \
    gopls version | head -1; dlv version | head -1; wails3 version 2>&1 | head -1

# -----------------------------------------------------------------------------
# L9) misc dev tools
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends lsof poppler-utils; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# L10) Node runtime tools + Cloudflare Workers toolchain
#      wrangler bundles workerd/miniflare transitively - do NOT install them.
# -----------------------------------------------------------------------------
RUN set -eux; \
    npm install -g bun pm2 tsx esbuild vite wrangler create-cloudflare; \
    npm cache clean --force; \
    bun --version; pm2 --version; tsx --version; esbuild --version; vite --version; wrangler --version

# -----------------------------------------------------------------------------
# L11) paseo CLI (daemon + bundled Web UI) + OpenCode = LATEST V1 ONLY.
#      NEVER install `@opencode/cli` (that is V2 and shares the `opencode` bin).
#      The symlink in /root/.opencode/bin is what the OpenCode DESKTOP app probes
#      inside a WSL distro (it never searches PATH); scripts/wsl-boot.sh recreates
#      it on every boot because /root is bind-mounted from the data disk.
# -----------------------------------------------------------------------------
RUN set -eux; \
    npm install -g @getpaseo/cli "opencode-ai@^1"; \
    npm cache clean --force; \
    paseo --version; opencode --version; \
    mkdir -p /root/.opencode/bin; \
    ln -sfn /usr/local/bin/opencode /root/.opencode/bin/opencode; \
    test -x /root/.opencode/bin/opencode

# -----------------------------------------------------------------------------
# L11a) MCP adapter packages for the managed OpenCode global config (L11b).
#       CACHEBUST forces a rebuild of the floating @latest installs; the
#       managed config always references these ABSOLUTE paths, never npx/uvx.
#       open-websearch intentionally replaces omo's Exa-backed `websearch`.
# -----------------------------------------------------------------------------
ARG CACHEBUST=0
ARG MMS_VERSION=13.0.0
ARG MCP_DAP_VERSION=v0.0.0-20261103230859-6011c2cd13e8
RUN set -eux; \
    echo "mcp adapter cachebust=${CACHEBUST}"; \
    npm install -g open-websearch@latest shadcn@latest @playwright/mcp@latest; \
    npm cache clean --force; \
    command -v open-websearch; command -v shadcn; command -v playwright-mcp
RUN set -eux; \
    UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin \
      uv tool install "mcp-memory-service[sqlite]==${MMS_VERSION}"
RUN set -eux; \
    GOBIN=/usr/local/bin go install "github.com/go-delve/mcp-dap-server@${MCP_DAP_VERSION}"; \
    test -x /usr/local/bin/mcp-dap-server

# -----------------------------------------------------------------------------
# L11b) managed OpenCode V1 global config + memory runtime assets.
#       /etc/opencode/opencode.json is applied last as the global config, so it
#       stays strict JSON with ONLY $schema + mcp. There is deliberately NO
#       `plugin` key: omo owns the plugin array, and a managed array would
#       replace oh-my-openagent at runtime.
#       config/agent-memory/ is copied as a directory so a missing source fails
#       the build (no `|| true`); T1b vendors the OpenCode memory plugin there
#       and verifies it against config/agent-memory/SHA256SUMS before shipping.
# -----------------------------------------------------------------------------
COPY config/opencode/global-mcp.json /etc/opencode/opencode.json
COPY config/agent-memory/ /opt/agent-memory/
RUN set -eux; \
    chmod 0644 /etc/opencode/opencode.json; \
    jq -e '.mcp | length == 8' /etc/opencode/opencode.json >/dev/null; \
    jq -e '(.mcp | has("context7") or has("grep_app") or has("lsp")) | not' /etc/opencode/opencode.json >/dev/null; \
    jq -e 'has("plugin") | not' /etc/opencode/opencode.json >/dev/null; \
    chmod -R a+rX /opt/agent-memory; \
    sh -c 'cd /opt/agent-memory && sha256sum -c SHA256SUMS'

# -----------------------------------------------------------------------------
# L12) Seed omo/OpenCode config OUTSIDE the mounted /home (bun required: npx is
#      known-broken for this installer in Docker builds). No blanket `|| true`.
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /opt/agent-seed/.config; \
    HOME=/opt/agent-seed XDG_CONFIG_HOME=/opt/agent-seed/.config OMO_DISABLE_POSTHOG=1 \
      bunx oh-my-openagent@latest install \
        --no-tui --platform=opencode --claude=no --gemini=no --copilot=no --skip-auth; \
    test -f /opt/agent-seed/.config/opencode/opencode.json; \
    jq '.plugin = ["oh-my-openagent@latest"]' /opt/agent-seed/.config/opencode/opencode.json > /tmp/oc.json; \
    mv /tmp/oc.json /opt/agent-seed/.config/opencode/opencode.json; \
    chmod -R a+rX /opt/agent-seed

# -----------------------------------------------------------------------------
# L13) non-root `paseo` user (uid/gid 1000).
#      The official node image already owns uid 1000 as user `node`, so remove it
#      first, otherwise `useradd -u 1000 paseo` fails.
# -----------------------------------------------------------------------------
RUN set -eux; \
    userdel -r node 2>/dev/null || true; \
    groupdel node 2>/dev/null || true; \
    groupadd --gid 1000 paseo; \
    useradd --uid 1000 --gid 1000 --create-home --home-dir /home/paseo --shell /bin/bash paseo; \
    mkdir -p /home/paseo /workspace; \
    chown -R paseo:paseo /home/paseo /workspace

# -----------------------------------------------------------------------------
# L14) config, shared scripts, bundled Windows helper
# -----------------------------------------------------------------------------
COPY config/wsl.conf /etc/wsl.conf
COPY config/wsl-distribution.conf /etc/wsl-distribution.conf
COPY config/profile.d/ /etc/profile.d/
COPY scripts/ /usr/local/bin/
RUN set -eux; chmod +x /usr/local/bin/*.sh; \
    mkdir -p /opt/agent-devbox/windows
COPY windows/ /opt/agent-devbox/windows/
RUN chmod -R a+rX /opt/agent-devbox

WORKDIR /workspace
EXPOSE 6767
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD ["node", "-e", "require('http').get({hostname:'127.0.0.1',port:6767,path:'/api/health'},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]

ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/docker-entrypoint.sh"]
