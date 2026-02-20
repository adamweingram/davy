# Agent Sandboxes
devbox() {
  local DOCKERFILE="/Users/adam/Docker/Dev-Sandbox/rocky.Dockerfile"
  local CONTEXT_DIR
  CONTEXT_DIR="$(dirname "$DOCKERFILE")"

  local IMAGE="${DEVBOX_IMAGE:-dev-sandbox:latest}"
  local PROJECT_DIR="$PWD"
  local NAME=""
  local REBUILD=0
  local NO_BUILD=0
  local KEEP=0
  local WITH_DOCKER_SOCK=0
  local WITH_EXPOSE_SSH=0
  local SSH_PORT=222
  local SSH_AUTH_KEYS_B64=""
  local WITH_PI_AUTH=0
  local WITH_CODEX_AUTH=0
  local WITH_GEMINI_AUTH=0
  local WITH_CLAUDE_AUTH=0
  local HOST_UID HOST_GID
  HOST_UID="$(id -u)"
  HOST_GID="$(id -g)"
  local CLAUDE_AUTH_VOLUME="${DEVBOX_CLAUDE_AUTH_VOLUME:-devbox-claude-auth-${HOST_UID}-v1}"

  # Arrays for extra docker args/envs/command
  local -a EXTRA_ENVS=()
  local -a EXTRA_ARGS=()
  local -a CMD=()

  # Auth management commands
  if [ "$#" -eq 3 ] && [ "$1" = "auth" ] && [ "$2" = "claude" ] && [ "$3" = "reset" ]; then
    if docker volume inspect "$CLAUDE_AUTH_VOLUME" >/dev/null 2>&1; then
      docker volume rm -f "$CLAUDE_AUTH_VOLUME" >/dev/null || return 1
      echo "devbox: removed Claude auth volume '$CLAUDE_AUTH_VOLUME'" >&2
    else
      echo "devbox: Claude auth volume '$CLAUDE_AUTH_VOLUME' does not exist" >&2
    fi
    return 0
  fi

  _devbox_help() {
    cat <<'EOF'
Usage:
  devbox [options] [-- command...]
  devbox auth claude reset

Options:
  -p, --project DIR     Mount DIR at /project (default: current directory)
  -n, --name NAME       Container name (default: devbox-<folder>-<timestamp>)
      --docker          Also mount host docker socket (/var/run/docker.sock)
      --rebuild         Force rebuild of the image before running
      --no-build        Do not build (fail if image missing)
      --keep            Do not --rm (container persists after exit)
  -e, --env KEY=VAL     Add an env var to the container (repeatable)
      --pass-env KEY    Forward an existing host env var by name (repeatable)
      --auth-pi         Mount host PI agent auth into container
      --auth-codex      Mount host Codex auth into container
      --auth-gemini     Mount host Gemini auth into container
      --auth-claude     Mount persistent Claude auth volume into container
      --auth-all        Enable --auth-pi --auth-codex --auth-gemini --auth-claude
  -s, --expose-ssh [PORT]
                      Publish host PORT to container port 22 (default: 222)
                      Login user: dev (public key auth only)
                      Keys source: ~/.ssh/authorized_keys + ~/.ssh/*.pub
                      Override with DEVBOX_SSH_AUTHORIZED_KEYS_FILE=/path/to/file
  -h, --help            Show this help

Auth management:
  devbox auth claude reset
                      Delete the Claude auth volume
                      (default: devbox-claude-auth-<uid>-v1)

Examples:
  devbox
  devbox --docker
  devbox --auth-claude
  devbox --auth-all
  devbox -p ~/code/myproj --rebuild
  devbox -e OPENAI_API_KEY="$OPENAI_API_KEY" --pass-env ANTHROPIC_API_KEY
  devbox -- npm test
EOF
  }

  # Parse args (bash 3.x compatible)
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--project) PROJECT_DIR="$2"; shift 2 ;;
      -n|--name) NAME="$2"; shift 2 ;;
      --docker) WITH_DOCKER_SOCK=1; shift ;;
      --rebuild) REBUILD=1; shift ;;
      --no-build) NO_BUILD=1; shift ;;
      --keep) KEEP=1; shift ;;
      -s|--expose-ssh)
        WITH_EXPOSE_SSH=1
        if [ $# -gt 1 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
          SSH_PORT="$2"
          shift 2
        else
          shift
        fi
        ;;
      --expose-ssh=*)
        WITH_EXPOSE_SSH=1
        SSH_PORT="${1#*=}"
        shift
        ;;
      -e|--env) EXTRA_ENVS+=("-e" "$2"); shift 2 ;;
      --pass-env)
        if [ -n "$2" ]; then
          EXTRA_ENVS+=("-e" "$2=${!2}")
        fi
        shift 2
        ;;
      --auth-pi|--pi-auth) WITH_PI_AUTH=1; shift ;;
      --auth-codex|--codex-auth) WITH_CODEX_AUTH=1; shift ;;
      --auth-gemini|--gemini-auth) WITH_GEMINI_AUTH=1; shift ;;
      --auth-claude|--claude-auth) WITH_CLAUDE_AUTH=1; shift ;;
      --auth-all) WITH_PI_AUTH=1; WITH_CODEX_AUTH=1; WITH_GEMINI_AUTH=1; WITH_CLAUDE_AUTH=1; shift ;;
      -h|--help) _devbox_help; return 0 ;;
      --) shift; CMD=("$@"); break ;;
      *) EXTRA_ARGS+=("$1"); shift ;;
    esac
  done

  if [ "$WITH_EXPOSE_SSH" -eq 1 ]; then
    case "$SSH_PORT" in
      ''|*[!0-9]*)
        echo "devbox: invalid SSH port '$SSH_PORT' (expected 1-65535)" >&2
        return 1
        ;;
    esac
    if [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
      echo "devbox: invalid SSH port '$SSH_PORT' (expected 1-65535)" >&2
      return 1
    fi
  fi

  if [ "$WITH_PI_AUTH" -eq 1 ]; then
    EXTRA_ARGS+=("-v" "${HOME}/.pi/agent:/home/dev/.pi/agent")
  fi
  if [ "$WITH_CODEX_AUTH" -eq 1 ]; then
    EXTRA_ARGS+=("-v" "${HOME}/.codex:/home/dev/.codex")
    EXTRA_ENVS+=("-e" "CODEX_HOME=/home/dev/.codex")
  fi
  if [ "$WITH_GEMINI_AUTH" -eq 1 ]; then
    EXTRA_ARGS+=("-v" "${HOME}/.gemini:/home/dev/.gemini")
  fi

  # Validate paths
  if [ ! -f "$DOCKERFILE" ]; then
    echo "devbox: Dockerfile not found at: $DOCKERFILE" >&2
    return 1
  fi
  if [ ! -d "$PROJECT_DIR" ]; then
    echo "devbox: project dir not found: $PROJECT_DIR" >&2
    return 1
  fi

  # Build image (optionally)
  if [ "$NO_BUILD" -eq 0 ]; then
    if [ "$REBUILD" -eq 1 ]; then
      # Use `DOCKER_BUILDKIT=1` if you want to use buildkit
      docker build --pull \
        --build-arg USER_UID="$HOST_UID" \
        --build-arg USER_GID="$HOST_GID" \
        -f "$DOCKERFILE" -t "$IMAGE" "$CONTEXT_DIR" || return 1
    else
      if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        docker build \
          --build-arg USER_UID="$HOST_UID" \
          --build-arg USER_GID="$HOST_GID" \
          -f "$DOCKERFILE" -t "$IMAGE" "$CONTEXT_DIR" || return 1
      fi
    fi
  else
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
      echo "devbox: image '$IMAGE' not found (and --no-build was set)" >&2
      return 1
    fi
  fi

  if [ "$WITH_CLAUDE_AUTH" -eq 1 ]; then
    docker volume create "$CLAUDE_AUTH_VOLUME" >/dev/null || return 1

    # First use of a named volume is root-owned. Initialize and chown once for the dev user.
    docker run --rm --user 0:0 \
      -v "${CLAUDE_AUTH_VOLUME}:/auth" \
      "$IMAGE" \
      bash -lc "mkdir -p /auth/.claude && touch /auth/.claude.json && chown -R ${HOST_UID}:${HOST_GID} /auth" >/dev/null || return 1
  fi

  if [ "$WITH_EXPOSE_SSH" -eq 1 ]; then
    local pub
    local SSH_AUTH_KEYS_CONTENT=""

    if [ -n "${DEVBOX_SSH_AUTHORIZED_KEYS_FILE:-}" ]; then
      if [ ! -f "${DEVBOX_SSH_AUTHORIZED_KEYS_FILE}" ]; then
        echo "devbox: DEVBOX_SSH_AUTHORIZED_KEYS_FILE not found: ${DEVBOX_SSH_AUTHORIZED_KEYS_FILE}" >&2
        return 1
      fi
      SSH_AUTH_KEYS_CONTENT="$(awk 'NF && !seen[$0]++' "${DEVBOX_SSH_AUTHORIZED_KEYS_FILE}")"
    else
      SSH_AUTH_KEYS_CONTENT="$({
        if [ -f "${HOME}/.ssh/authorized_keys" ]; then
          cat "${HOME}/.ssh/authorized_keys"
        fi
        for pub in "${HOME}"/.ssh/*.pub; do
          if [ -f "$pub" ]; then
            cat "$pub"
          fi
        done
      } | awk 'NF && !seen[$0]++')"
    fi

    if [ -z "$SSH_AUTH_KEYS_CONTENT" ]; then
      echo "devbox: no SSH public keys found. Add ~/.ssh/*.pub or set DEVBOX_SSH_AUTHORIZED_KEYS_FILE." >&2
      return 1
    fi

    SSH_AUTH_KEYS_B64="$(printf '%s\n' "$SSH_AUTH_KEYS_CONTENT" | base64 | tr -d '\n')"
    if [ -z "$SSH_AUTH_KEYS_B64" ]; then
      echo "devbox: failed to encode SSH authorized_keys content." >&2
      return 1
    fi

    EXTRA_ENVS+=("-e" "DEVBOX_SSH_AUTH_KEYS_B64=${SSH_AUTH_KEYS_B64}")
  fi

  # Name default
  if [ -z "$NAME" ]; then
    local base ts
    base="$(basename "$PROJECT_DIR")"
    ts="$(date +%Y%m%d-%H%M%S)"
    NAME="devbox-${base}-${ts}"
  fi

  # Run args
  local -a RUN_ARGS
  RUN_ARGS=(-it)
  if [ "$KEEP" -eq 0 ]; then
    RUN_ARGS+=(--rm)
  fi

  RUN_ARGS+=(--name "$NAME")
  RUN_ARGS+=(-v "${PROJECT_DIR}:/project" -w /project)

  if [ "$WITH_CLAUDE_AUTH" -eq 1 ]; then
    RUN_ARGS+=(--mount "type=volume,src=${CLAUDE_AUTH_VOLUME},dst=/home/dev/.claude-auth")
  fi

  if [ "$WITH_DOCKER_SOCK" -eq 1 ]; then
    RUN_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
  fi
  if [ "$WITH_EXPOSE_SSH" -eq 1 ]; then
    RUN_ARGS+=(-p "${SSH_PORT}:22")
  fi

  # Start shell if no command provided
  if [ "${#CMD[@]}" -eq 0 ]; then
    CMD=(bash)
  fi

  if [ "$WITH_CLAUDE_AUTH" -eq 1 ]; then
    local -a ORIGINAL_CMD
    ORIGINAL_CMD=("${CMD[@]}")
    CMD=(
      bash -lc
      'set -e
mkdir -p /home/dev/.claude-auth/.claude
touch /home/dev/.claude-auth/.claude.json

if [ -e /home/dev/.claude ] && [ ! -L /home/dev/.claude ]; then
  rm -rf /home/dev/.claude
fi
if [ -e /home/dev/.claude.json ] && [ ! -L /home/dev/.claude.json ]; then
  rm -f /home/dev/.claude.json
fi

ln -sfn /home/dev/.claude-auth/.claude /home/dev/.claude
ln -sfn /home/dev/.claude-auth/.claude.json /home/dev/.claude.json
export CLAUDE_CONFIG_DIR=/home/dev/.claude

exec "$@"'
      --
      "${ORIGINAL_CMD[@]}"
    )
  fi

  if [ "$WITH_EXPOSE_SSH" -eq 1 ]; then
    local -a ORIGINAL_CMD
    ORIGINAL_CMD=("${CMD[@]}")
    CMD=(
      bash -lc
      'set -e
if ! command -v sshd >/dev/null 2>&1; then
  echo "devbox: sshd is not installed in image. Rebuild with the latest rocky.Dockerfile." >&2
  exit 1
fi

if [ -z "${DEVBOX_SSH_AUTH_KEYS_B64:-}" ]; then
  echo "devbox: DEVBOX_SSH_AUTH_KEYS_B64 is missing." >&2
  exit 1
fi

mkdir -p /home/dev/.ssh
chmod 700 /home/dev/.ssh
if ! printf "%s" "$DEVBOX_SSH_AUTH_KEYS_B64" | base64 -d >/home/dev/.ssh/authorized_keys 2>/dev/null; then
  printf "%s" "$DEVBOX_SSH_AUTH_KEYS_B64" | base64 --decode >/home/dev/.ssh/authorized_keys
fi
if [ ! -s /home/dev/.ssh/authorized_keys ]; then
  echo "devbox: decoded authorized_keys is empty." >&2
  exit 1
fi
chmod 600 /home/dev/.ssh/authorized_keys

sudo mkdir -p /run/sshd
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  sudo ssh-keygen -A >/dev/null
fi

sudo /usr/sbin/sshd \
  -o PermitRootLogin=no \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o ChallengeResponseAuthentication=no \
  -o PubkeyAuthentication=yes \
  -o AuthorizedKeysFile=.ssh/authorized_keys \
  -o PidFile=/tmp/devbox-sshd.pid

exec "$@"'
      --
      "${ORIGINAL_CMD[@]}"
    )
  fi

  # Security reminder when enabling docker socket
  if [ "$WITH_DOCKER_SOCK" -eq 1 ]; then
    echo "devbox: docker socket mounted. Container can control host Docker." >&2
  fi
  if [ "$WITH_EXPOSE_SSH" -eq 1 ]; then
    echo "devbox: exposing host port ${SSH_PORT} to container port 22." >&2
    echo "devbox: SSH login user is 'dev' (key auth only)." >&2
  fi
  if [ "$WITH_CLAUDE_AUTH" -eq 1 ]; then
    echo "devbox: Claude auth volume mounted at /home/dev/.claude-auth (${CLAUDE_AUTH_VOLUME})." >&2
    echo "devbox: first use requires running 'claude login' in-container." >&2
  fi

  local run_status
  docker run "${RUN_ARGS[@]}" "${EXTRA_ENVS[@]}" "${EXTRA_ARGS[@]}" "$IMAGE" "${CMD[@]}"
  run_status=$?

  return "$run_status"
}
