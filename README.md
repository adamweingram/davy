A simple Docker-based sandbox for running agents with a bash function interface.

## "Install"
```zsh
. /this/dir/sourceme.sh
```

## Claude auth (persistent, opt-in)
Use `--auth-claude` to mount a persistent Docker volume for Claude login state:

```zsh
devbox --auth-claude
```

Reset that auth volume:

```zsh
devbox auth claude reset
```

Volume name defaults to `devbox-claude-auth-<uid>-v1` and can be overridden with `DEVBOX_CLAUDE_AUTH_VOLUME`.

## All auths at once
Use `--auth-all` to enable auth setup for Pi, Codex, Gemini, and Claude in one command.

## SSH access
Expose SSH on host port `222` (or pass a custom port):

```zsh
devbox --expose-ssh
devbox --expose-ssh 2200
```

Then connect:

```zsh
ssh -p 222 dev@localhost
```

Notes:
- SSH login is user `dev`, key-only auth (password auth disabled).
- Keys are populated from `~/.ssh/authorized_keys` and `~/.ssh/*.pub` on the host.
- Set `DEVBOX_SSH_AUTHORIZED_KEYS_FILE=/path/to/authorized_keys` to override key source.
- Rebuild once after pulling changes so `openssh-server` is present: `devbox --rebuild`.
