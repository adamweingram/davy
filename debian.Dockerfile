# syntax=docker/dockerfile:1.6

FROM debian:bookworm-slim

ARG USERNAME=dev
ARG USER_UID=1000 # IS OVERRIDDEN DURING BUILD AND RUN BY `devbox` BASH FUNCTION!
ARG USER_GID=${USER_UID}

# Pin Node however you like at build time:
#   docker build --build-arg NODE_VERSION=22.11.0 -t agent-dev .
ARG NODE_VERSION=25.6.1
ARG NODE_DISTRO=linux-arm64 # Change to `linux-x64` on x86

ENV DEBIAN_FRONTEND=noninteractive \
    PROJECT_DIR=/project

# Base tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git openssh-client \
      build-essential pkg-config \
      python3 python3-venv python3-pip \
      jq ripgrep fd-find less unzip zip xz-utils \
      sudo zsh tmux \
      docker.io \
      gnupg \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (official tarball + checksum verification)
RUN set -eux; \
    cd /tmp; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-${NODE_DISTRO}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    grep " node-v${NODE_VERSION}-${NODE_DISTRO}.tar.xz\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "node-v${NODE_VERSION}-${NODE_DISTRO}.tar.xz" -C /usr/local --strip-components=1; \
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

# Install agent CLIs globally
# - codex  -> @openai/codex
# - claude -> @anthropic-ai/claude-code
# - gemini -> @google/gemini-cli
# - pi     -> @mariozechner/pi-coding-agent
RUN npm install -g --no-fund --no-audit \
      @openai/codex \
      @anthropic-ai/claude-code \
      @google/gemini-cli \
      @mariozechner/pi-coding-agent \
 && npm cache clean --force

# Workspace
RUN mkdir -p "${PROJECT_DIR}" \
 && chown -R "${USER_UID}:${USER_GID}" "${PROJECT_DIR}"

USER "${USERNAME}"
WORKDIR "${PROJECT_DIR}"

ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

CMD ["bash"]
