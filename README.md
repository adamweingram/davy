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
