# syntax=docker/dockerfile:1.6
FROM rockylinux:9

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=${USER_UID}

ARG NODE_VERSION=25.6.1
ARG NODE_DISTRO=""
ARG TARGETARCH

ENV PROJECT_DIR=/project
ENV PATH=/home/${USERNAME}/.cargo/bin:/home/${USERNAME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Base tooling + repos + Docker CLI
RUN set -eux; \
    dnf -y update; \
    dnf -y install dnf-plugins-core shadow-utils ca-certificates; \
    \
    # Rocky image ships with curl-minimal; swap to full curl to avoid conflicts
    dnf -y swap --allowerasing curl-minimal curl; \
    \
    dnf -y install \
    bash git openssh-clients openssh-server wget \
    sudo zsh tmux \
    gcc gcc-c++ make pkgconf-pkg-config \
    python3 python3-pip \
    jq less unzip zip xz tar gzip findutils which; \
    \
    # Enable CRB + EPEL for ripgrep/fd-find
    dnf config-manager --set-enabled crb; \
    dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm; \
    dnf -y install ripgrep fd-find; \
    \
    # Ensure `fd` exists (some distros call it fdfind)
    if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then \
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd; \
    fi; \
    \
    # Docker CLI (useful if you mount /var/run/docker.sock)
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo; \
    dnf -y install docker-ce-cli; \
    \
    dnf clean all; \
    rm -rf /var/cache/dnf

# Install Node.js (official tarball + checksum verification)
RUN set -eux; \
    distro="${NODE_DISTRO:-}"; \
    if [ -z "$distro" ]; then \
    arch="$(uname -m)"; \
    case "$arch" in \
    x86_64|amd64) distro="linux-x64" ;; \
    aarch64|arm64) distro="linux-arm64" ;; \
    *) echo "Unsupported arch: ${arch}. Set NODE_DISTRO explicitly (linux-x64/linux-arm64)." >&2; exit 1 ;; \
    esac; \
    fi; \
    cd /tmp; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-${distro}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    grep " node-v${NODE_VERSION}-${distro}.tar.xz\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "node-v${NODE_VERSION}-${distro}.tar.xz" -C /usr/local --strip-components=1; \
    rm -rf /tmp/*; \
    node --version; npm --version; \
    corepack enable || true

# Non-root user (matches host UID/GID for mounted volumes)
RUN set -eux; \
    if ! getent group "${USER_GID}" >/dev/null; then \
    groupadd --gid "${USER_GID}" "${USERNAME}"; \
    fi; \
    useradd --uid "${USER_UID}" --gid "${USER_GID}" -m -s /bin/bash "${USERNAME}"; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Agent CLIs
RUN npm install -g --no-fund --no-audit \
    @openai/codex \
    @google/gemini-cli \
    @mariozechner/pi-coding-agent \
    && npm cache clean --force

# Workspace
RUN mkdir -p "${PROJECT_DIR}" && chown -R "${USER_UID}:${USER_GID}" "${PROJECT_DIR}"

USER "${USERNAME}"

# MUST happen after switching user
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y && echo '. "$HOME/.cargo/env"' >> ~/.bashrc
RUN cargo install --locked hyperfine && \
    cargo install --locked hexyl && \
    cargo install --locked bat

WORKDIR "${PROJECT_DIR}"
CMD ["bash"]
