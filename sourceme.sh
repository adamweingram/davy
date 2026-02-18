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

  # Arrays for extra docker args/envs/command
  local -a EXTRA_ENVS=()
  local -a EXTRA_ARGS=()
  local -a CMD=()

  _devbox_help() {
    cat <<'EOF'
Usage:
  devbox [options] [-- command...]

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
  -h, --help            Show this help

Examples:
  devbox
  devbox --docker
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
      -e|--env) EXTRA_ENVS+=("-e" "$2"); shift 2 ;;
      --pass-env)
        if [ -n "$2" ]; then
          EXTRA_ENVS+=("-e" "$2=${!2}")
        fi
        shift 2
        ;;
      --auth-pi|--pi-auth) EXTRA_ARGS+=("-v" "${HOME}/.pi/agent:/home/dev/.pi/agent"); shift ;;
      --auth-codex|--codex-auth) EXTRA_ARGS+=("-v" "${HOME}/.codex:/home/dev/.codex" "-e" "CODEX_HOME=/home/dev/.codex"); shift ;;
      --auth-gemini|--gemini-auth) EXTRA_ARGS+=("-v" "${HOME}/.gemini:/home/dev/.gemini"); shift ;;
      -h|--help) _devbox_help; return 0 ;;
      --) shift; CMD=("$@"); break ;;
      *) EXTRA_ARGS+=("$1"); shift ;;
    esac
  done

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
    local UID_ARG GID_ARG
    UID_ARG="$(id -u)"
    GID_ARG="$(id -g)"

    if [ "$REBUILD" -eq 1 ]; then
      # Use `DOCKER_BUILDKIT=1` if you want to use buildkit
      docker build --pull \
        --build-arg USER_UID="$UID_ARG" \
        --build-arg USER_GID="$GID_ARG" \
        -f "$DOCKERFILE" -t "$IMAGE" "$CONTEXT_DIR" || return 1
    else
      if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        docker build \
          --build-arg USER_UID="$UID_ARG" \
          --build-arg USER_GID="$GID_ARG" \
          -f "$DOCKERFILE" -t "$IMAGE" "$CONTEXT_DIR" || return 1
      fi
    fi
  else
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
      echo "devbox: image '$IMAGE' not found (and --no-build was set)" >&2
      return 1
    fi
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

  if [ "$WITH_DOCKER_SOCK" -eq 1 ]; then
    RUN_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
  fi

  # Start shell if no command provided
  if [ "${#CMD[@]}" -eq 0 ]; then
    CMD=(bash)
  fi

  # Security reminder when enabling docker socket
  if [ "$WITH_DOCKER_SOCK" -eq 1 ]; then
    echo "devbox: docker socket mounted. Container can control host Docker." >&2
  fi

  docker run "${RUN_ARGS[@]}" "${EXTRA_ENVS[@]}" "${EXTRA_ARGS[@]}" "$IMAGE" "${CMD[@]}"
}
