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

# Rebuild image first, then run
davy --rebuild

# Use a specific project directory
davy -p ~/code/myproj

# Pass env vars
davy -e OPENAI_API_KEY="$OPENAI_API_KEY" --pass-env ANTHROPIC_API_KEY

# Mount Docker socket
davy --docker

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
1. `./rocky.Dockerfile`
2. `./debian.Dockerfile`

Override with:
- `--dockerfile /path/to/Dockerfile`
- `DAVY_DOCKERFILE=/path/to/Dockerfile`

## Environment Variables

- `DAVY_IMAGE` (default: `davy-sandbox:latest`)
- `DAVY_DOCKERFILE` (optional Dockerfile path)
- `DAVY_CLAUDE_AUTH_VOLUME` (default: `davy-claude-auth-<uid>-v1`)
- `DAVY_SSH_AUTHORIZED_KEYS_FILE` (optional path to authorized keys source)

## SSH Notes

When `--expose-ssh` is enabled:
- host port defaults to `222`
- login user is `dev`
- only public key auth is enabled
- keys are sourced from `~/.ssh/authorized_keys` and `~/.ssh/*.pub` unless `DAVY_SSH_AUTHORIZED_KEYS_FILE` is set
- `~/.agents/skills` is always mounted at `/home/dev/.agents/skills`
