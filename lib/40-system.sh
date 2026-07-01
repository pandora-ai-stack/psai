# ───────────────────────────── privilege detection ─────────────────────────────
is_admin() {
  detect_os
  case "$OS_TYPE" in
    macos)
      id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin && return 0
      dscl . -read /Groups/admin GroupMembership 2>/dev/null | tr ' ' '\n' | grep -qx "$(id -un)" && return 0
      return 1 ;;
    linux)
      id -Gn 2>/dev/null | tr ' ' '\n' | grep -Eqx 'sudo|wheel|root' && return 0
      [ "$(id -u)" = "0" ] && return 0
      return 1 ;;
    *) return 1 ;;
  esac
}

# Can we actually run sudo? True if root, passwordless sudo, or an admin user on a TTY.
can_use_sudo() {
  command_exists sudo || { [ "$(id -u)" = "0" ] && return 0 || return 1; }
  sudo -n true >/dev/null 2>&1 && return 0
  if is_admin && [ -t 0 ]; then return 0; fi
  return 1
}

# ───────────────────────────── docker / path ─────────────────────────────
ensure_path_brew() {
  case ":$PATH:" in
    *":/opt/homebrew/bin:"*) ;;
    *) [ -d /opt/homebrew/bin ] && PATH="/opt/homebrew/bin:$PATH" ;;
  esac
  case ":$PATH:" in
    *":/usr/local/bin:"*) ;;
    *) [ -d /usr/local/bin ] && PATH="/usr/local/bin:$PATH" ;;
  esac
  export PATH
  # Pin docker to the context recorded at install, so a host running both Colima and
  # Docker Desktop can't have the installer manage the wrong daemon between runs.
  [ -n "${DOCKER_CONTEXT_PIN:-}" ] && export DOCKER_CONTEXT="$DOCKER_CONTEXT_PIN"
  return 0
}

# Record the docker context actually in use (after Colima is up) so future runs target the
# same daemon. An explicit PSAI_DOCKER_CONTEXT wins; "default" isn't worth pinning (it's the
# ambient single daemon, e.g. on Linux).
capture_docker_context() {
  [ -n "${DOCKER_CONTEXT_PIN:-}" ] && { export DOCKER_CONTEXT="$DOCKER_CONTEXT_PIN"; return 0; }
  command_exists docker || return 0
  local ctx; ctx="$(docker context show 2>/dev/null || true)"
  if [ -n "$ctx" ] && [ "$ctx" != "default" ]; then
    DOCKER_CONTEXT_PIN="$ctx"; export DOCKER_CONTEXT="$ctx"
  fi
  return 0
}

detect_docker_sock() {
  if [ -S /var/run/docker.sock ] || [ -L /var/run/docker.sock ]; then
    DOCKER_SOCK="/var/run/docker.sock"; return 0
  fi
  local host=""
  command_exists docker && host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  case "$host" in
    unix://*) DOCKER_SOCK="${host#unix://}" ;;
    *)        DOCKER_SOCK="/var/run/docker.sock" ;;
  esac
  [ -n "$DOCKER_SOCK" ] || DOCKER_SOCK="/var/run/docker.sock"
  return 0
}

# OpenHands socket: rootless mode uses the user runtime socket; otherwise the resolved one.
resolve_openhands_socket() {
  case "$OPENHANDS_DOCKER_MODE" in
    rootless) DOCKER_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock" ;;
    *)        detect_docker_sock ;;
  esac
}

nvidia_host_detected() {
  detect_os
  [ "$OS_TYPE" = "linux" ] || return 1
  command_exists nvidia-smi && nvidia-smi -L >/dev/null 2>&1
}

nvidia_docker_runtime_ready() {
  command_exists docker || return 1
  docker info 2>/dev/null | grep -qiE 'nvidia'
}

# Can docker give a container a GPU for Ollama? Prints: nvidia | none.
# macOS: the Linux VM (colima/Docker Desktop) has NO GPU passthrough — CPU only, even on Apple
# Silicon (Metal isn't visible inside the Linux container). Linux: needs an NVIDIA GPU + the
# nvidia container toolkit so `docker --gpus` works.
gpu_runtime() {
  if nvidia_host_detected && nvidia_docker_runtime_ready; then
    printf 'nvidia'; return 0
  fi
  printf 'none'
}
# A model that runs acceptably given the detected OS/arch/hardware.
gpu_default_model() {
  { [ "$(gpu_runtime)" = "nvidia" ] || nvidia_host_detected; } && { printf 'gemma3:4b'; return 0; }
  detect_os 2>/dev/null || true
  case "${OS_TYPE:-}:$(uname -m 2>/dev/null)" in
    macos:arm64|macos:aarch64) printf 'gemma4:e2b-it-q4_K_M' ;;
    *)                         printf 'gemma3:1b' ;;
  esac
}

# Interactive default for RAG-plus. Linux/x64 can run the Infinity embed+rerank
# image natively. macOS and Linux/arm64 default to plus only when Ollama is in
# the plan, because the installer will use Ollama embeddings there instead.
rag_plus_default_answer() {
  detect_os
  case "${OS_TYPE:-unknown}:${ARCH_TYPE:-unknown}" in
    linux:x64) printf 'Y' ;;
    macos:*|linux:arm64)
      [ "${LOCAL_LLM:-none}" = "ollama" ] && printf 'Y' || printf 'N' ;;
    *) printf 'N' ;;
  esac
}

start_colima_if_needed() {
  [ "$OS_TYPE" = "macos" ] || return 0
  command_exists docker || return 0
  docker info >/dev/null 2>&1 && return 0
  if command_exists colima; then
    printf '%s\n' "$(t env_colima)"
    colima status >/dev/null 2>&1 || colima start --cpu 4 --memory 8 --disk 60 || colima start || true
  fi
}

# ───────────────────────────── compose plumbing ─────────────────────────────
sevenzip_detect() {
  if command_exists 7zz; then SEVENZIP_BIN="7zz"
  elif command_exists 7z; then SEVENZIP_BIN="7z"
  elif command_exists 7za; then SEVENZIP_BIN="7za"
  else SEVENZIP_BIN=""; fi
}

# A single generated compose file lives in $STACK_DIR/compose/ (no upstream repo).
compose() { (cd "$STACK_DIR/compose" && docker compose -f docker-compose.yml "$@"); }
validate_compose() { compose config >/dev/null; }

docker_state() {
  if ! command_exists docker; then printf '%s' "$(t st_not_installed)"; return; fi
  if docker info >/dev/null 2>&1; then printf '%s' "$(t st_running)"; else printf '%s ✗' "$(t st_stopped)"; fi
}
