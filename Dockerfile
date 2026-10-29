# syntax=docker/dockerfile:1.7
# =============================================================================
# agent-devbox-core — paseo (daemon + bundled Web UI) + OpenCode (latest V1) +
#                     omo (oh-my-openagent) + a broad dev/test toolchain.
#
# Base: node:22-trixie-slim  (Debian 13 "trixie", Node 22.x)
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
FROM node:22-trixie-slim

ARG PLAYWRIGHT_VERSION=1.64.1
ARG GO_VERSION=1.27.2

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
    GOSUMDB=off \
    IS_DOCKER=true \
    PATH=/usr/local/go/bin:/usr/local/bin:$PATH
# HOME is deliberately NOT set globally: the WSL root shell must keep HOME=/root.
# paseo-boot.sh exports HOME=/home/paseo for the daemon only.

# Use bash with pipefail so any RUN pipeline fails fast (satisfies hadolint DL4006).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

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
#      `marksman` has no Debian package -> GitHub release binary, arch-mapped.
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
    case "$(dpkg --print-architecture)" in \
      amd64) marksman_arch=x64 ;; \
      arm64) marksman_arch=arm64 ;; \
      *) echo "unsupported arch: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
      -o /usr/local/bin/marksman \
      "https://github.com/artempyanykh/marksman/releases/latest/download/marksman-linux-${marksman_arch}"; \
    chmod +x /usr/local/bin/marksman; \
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
    chmod -R 777 /ms-playwright; \
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
# L6) Python tooling: uv
# -----------------------------------------------------------------------------
RUN set -eux; \
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

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
# -----------------------------------------------------------------------------
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm -f /tmp/go.tgz; \
    ln -sf /usr/local/go/bin/go /usr/local/bin/go; \
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt; \
    go version

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
