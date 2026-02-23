# davy

A simple Docker-based sandbox runner for agent workflows. That's all. It just runs docker commands.

## Build and Run

```zsh
cargo run -- --help
```

Install as a local binary:

```zsh
cargo install --path .
```

The installed executable is `davy`.

Optional compatibility mode (legacy shell script; you probably don't need it):

```zsh
. /path/to/davy/sourceme.sh
```

## Usage

```zsh
davy [options] [extra docker args] [-- command...]
davy auth claude reset
```

Examples:

```zsh
# Interactive shell in /project
# (builds image if needed)
davy

# Rebuild image first (pull base + no cache), then run
davy --rebuild

# Use a specific project directory
davy -p ~/code/myproj

# Pass env vars
davy -e OPENAI_API_KEY="$OPENAI_API_KEY" --pass-env ANTHROPIC_API_KEY

# Mount Docker socket
davy --docker

# Mount a specific Docker socket path (useful on Linux rootless Docker)
davy --docker --docker-sock /run/user/1000/docker.sock

# Enable persistent Claude auth
davy --auth-claude

# Enable all auth mounts (Pi, Codex, Gemini, Claude)
davy --auth-all

# Expose SSH on default host port 222
davy --expose-ssh

# Expose SSH on custom port
davy --expose-ssh 2200

# Run a command instead of bash
davy -- npm test

# Reset Claude auth volume
davy auth claude reset
```

## Dockerfile Resolution

By default, `davy` looks for:
1. `~/.config/davy/rocky.Dockerfile`
2. `~/.config/davy/debian.Dockerfile`

Use `--local-dockerfile` to search the current directory instead:
1. `./rocky.Dockerfile`
2. `./debian.Dockerfile`

Override with a specific path:
- `--dockerfile /path/to/Dockerfile`
- `DAVY_DOCKERFILE=/path/to/Dockerfile`

## Environment Variables

- `DAVY_IMAGE` (default: `davy-sandbox:latest`)
- `DAVY_DOCKERFILE` (optional Dockerfile path)
- `DAVY_DOCKER_SOCK` (optional Docker socket path for `--docker`)
- `DAVY_CLAUDE_AUTH_VOLUME` (default: `davy-claude-auth-<uid>-v1`)
- `DAVY_SSH_AUTHORIZED_KEYS_FILE` (optional path to authorized keys source)

## SSH Notes

When `--expose-ssh` is enabled:
- host port defaults to `222`
- login user is `dev`
- only public key auth is enabled
- keys are sourced from `~/.ssh/authorized_keys` and `~/.ssh/*.pub` unless `DAVY_SSH_AUTHORIZED_KEYS_FILE` is set
- if present, `~/.agents/skills` is mounted at `/home/dev/.agents/skills`

## Linux Notes

- With `--docker`, `davy` resolves the host socket from `--docker-sock`, then `DAVY_DOCKER_SOCK`, then `DOCKER_HOST=unix://...`, then `/var/run/docker.sock`.
  - If `DOCKER_HOST` is set to a non-unix endpoint (for example `tcp://...`), `--docker` requires `--docker-sock` (or `DAVY_DOCKER_SOCK`) so a local socket can be mounted. Alternatively, skip `--docker` entirely and forward the TCP endpoint directly into the container via `-e` and `--add-host`:
    ```sh
    davy -e DOCKER_HOST="tcp://host.docker.internal:2375" --add-host=host.docker.internal:host-gateway
    ```
- Auth directory mounts are validated before running. Explicit auth flags fail fast if host directories are missing; `--auth-all` skips missing auth directories with warnings.
- The skills mount (`~/.agents/skills`) is mounted only when the host directory exists.
