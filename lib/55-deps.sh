# ───────────────────────────── step 0 · environment ─────────────────────────────
# Required host tooling. Docker is the big one; the rest are tiny CLIs.
REQUIRED_DEPS="docker git curl openssl 7z"

dep_present() {
  case "$1" in
    docker) command_exists docker ;;
    7z)     sevenzip_detect; [ -n "$SEVENZIP_BIN" ] ;;
    *)      command_exists "$1" ;;
  esac
}

# One status row: ● name  state
env_row() {
  local name="$1" ok="$2" note="$3" dot="$C_GREEN" state
  if [ "$ok" = "true" ]; then state="$note"; else dot="$C_RED"; state="$(t env_missing)"; fi
  printf '    %s %-16s %s%s%s\n' "$(status_dot "$dot")" "$name" "$C_DIM" "$state" "$C_RESET"
}

# Print the environment status table (to STDERR, so the caller can capture the return
# value cleanly) and return ONLY the space-separated missing list on stdout. NOTE: the
# table MUST go to stderr — `missing="$(env_status)"` captures stdout, and if the table
# went there too, `missing` would never be empty and the installer would always think a
# package is missing (then `brew install` on the whole table text → hang on auto-update).
env_status() {
  detect_os; ensure_path_brew; sevenzip_detect
  printf '  %s%s%s\n' "$C_B$C_CYAN" "$(t env_checking)" "$C_RESET" >&2
  local missing="" d ok note
  for d in $REQUIRED_DEPS; do
    if dep_present "$d"; then ok="true"; else ok="false"; missing="$missing $d"; fi
    note="$(t env_ok)"
    [ "$d" = "docker" ] && [ "$ok" = "true" ] && { docker info >/dev/null 2>&1 && note="$(t st_running)" || note="$(t st_stopped)"; }
    env_row "$d" "$ok" "$note" >&2
  done
  # docker present but compose plugin missing?
  if command_exists docker && ! docker compose version >/dev/null 2>&1; then
    missing="$missing docker-compose"; env_row "docker compose" "false" "" >&2
  fi
  printf '%s' "$(trim "$missing")"
}

# Step 0 entry. Show the table; if anything is missing, install (asks password); re-check.
step0_env() {
  printf '\n%s%s%s\n' "$C_B" "$(t step0_title)" "$C_RESET"
  local missing; missing="$(env_status)"
  if [ -z "$missing" ]; then
    start_colima_if_needed
    ensure_nvidia_container_toolkit || return 1
    printf '  %s%s%s\n' "$C_GREEN" "$(t env_ready)" "$C_RESET"
    return 0
  fi
  install_missing_deps "$missing"
}

# Install Docker CE from Docker's official apt repository with a pinned, signed-by GPG key,
# instead of piping get.docker.com straight into a root shell (arbitrary unverified code).
# apt then verifies every package against the pinned key. Debian/Ubuntu (apt) only.
apt_install_docker_ce() {
  local S="${1:-}"
  command_exists docker && return 0
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || return 1
  local id="${ID:-debian}" code="${VERSION_CODENAME:-}"
  $S install -m 0755 -d /etc/apt/keyrings || return 1
  curl -fsSL "https://download.docker.com/linux/$id/gpg" | $S tee /etc/apt/keyrings/docker.asc >/dev/null || return 1
  $S chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$id" "$code" | $S tee /etc/apt/sources.list.d/docker.list >/dev/null
  $S apt-get update -qq
  $S apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

apt_install_nvidia_container_toolkit() {
  local S="${1:-}"
  command_exists apt-get || return 1
  # shellcheck disable=SC2086
  $S apt-get install -y -qq ca-certificates curl gnupg2 || return 1
  # shellcheck disable=SC2086
  $S install -m 0755 -d /usr/share/keyrings /etc/apt/sources.list.d || return 1
  # shellcheck disable=SC2086
  $S rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  # shellcheck disable=SC2086
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | $S gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg || return 1
  # shellcheck disable=SC2086
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | $S tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null || return 1
  # shellcheck disable=SC2086
  $S apt-get update -qq || return 1
  # shellcheck disable=SC2086
  $S apt-get install -y -qq nvidia-container-toolkit || return 1
  # shellcheck disable=SC2086
  $S nvidia-ctk runtime configure --runtime=docker || return 1
  # shellcheck disable=SC2086
  $S systemctl restart docker 2>/dev/null || $S service docker restart 2>/dev/null || true
}

ensure_nvidia_container_toolkit() {
  detect_os
  [ "$OS_TYPE" = "linux" ] || return 0
  nvidia_host_detected || return 0
  nvidia_docker_runtime_ready && return 0
  command_exists apt-get || { printf '  %s\n' "$(t dep_nvidia_manual)"; return 1; }
  local S=""
  if [ "$(id -u)" != "0" ]; then
    can_use_sudo || { printf '  %s\n' "$(t dep_need_root)"; return 1; }
    S="sudo"
  fi
  printf '  %s%s%s\n' "$C_YELLOW" "$(t dep_nvidia_install)" "$C_RESET"
  apt_install_nvidia_container_toolkit "$S" || { printf '  %s\n' "$(t dep_nvidia_failed)"; return 1; }
  if ! nvidia_docker_runtime_ready; then
    printf '  %s\n' "$(t dep_nvidia_failed)"
    return 1
  fi
}

# Install whatever is missing (brew on macOS, apt on Linux), then re-verify.
install_missing_deps() {
  local missing="$1"
  printf '\n  %s%s%s%s\n' "$C_YELLOW" "$(t env_need)" "$C_RESET" " $missing"

  if [ "$OS_TYPE" = "macos" ] && ! is_admin; then
    printf '  %s%s%s\n' "$C_YELLOW" "$(t env_need_admin)" "$C_RESET"
    printf '  %s\n' '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    printf '  %s\n' 'brew install colima docker docker-compose git openssl sevenzip'
    return 1
  fi
  confirm "$(t env_install_q)" 'Y' || { printf '  %s\n' "$(t env_manual)"; return 1; }

  case "$OS_TYPE" in
    macos)
      command_exists brew || { printf '  %s\n' "$(t env_no_brew)"; return 1; }
      local pkgs=""
      printf '%s' "$missing" | grep -q 'git'     && pkgs="$pkgs git"
      printf '%s' "$missing" | grep -q 'curl'    && pkgs="$pkgs curl"
      printf '%s' "$missing" | grep -q 'openssl' && pkgs="$pkgs openssl@3"
      printf '%s' "$missing" | grep -q '7z'      && pkgs="$pkgs sevenzip"
      printf '%s' "$missing" | grep -q 'docker'  && pkgs="$pkgs colima docker docker-compose"
      # shellcheck disable=SC2086
      [ -n "$(trim "$pkgs")" ] && brew install $pkgs
      start_colima_if_needed ;;
    linux)
      command_exists apt-get || { printf '  %s\n' "$(t dep_apt_only)"; return 1; }
      local S=""
      if [ "$(id -u)" != "0" ]; then can_use_sudo || { printf '  %s\n' "$(t dep_need_root)"; return 1; }; S="sudo"; fi
      # shellcheck disable=SC2086
      $S apt-get update
      # shellcheck disable=SC2086
      $S apt-get install -y git curl ca-certificates openssl p7zip-full gnupg2
      if printf '%s' "$missing" | grep -q 'docker'; then
        apt_install_docker_ce "$S" || { printf '  %s\n' "$(t dep_docker_failed)"; return 1; }
        $S systemctl enable --now docker 2>/dev/null || true
        if [ "$(id -u)" != "0" ]; then
          $S usermod -aG docker "$USER" 2>/dev/null || true
          printf '  %s\n' "$(t dep_docker_group)"
        fi
      fi ;;
    *) printf '  %s\n' "$(t dep_unknown_os)"; return 1 ;;
  esac

  # Re-verify so install never proceeds half-provisioned.
  ensure_path_brew; sevenzip_detect
  local still="" d
  for d in $REQUIRED_DEPS; do dep_present "$d" || still="$still $d"; done
  if [ -n "$(trim "$still")" ]; then
    printf '\n  %s%s%s%s\n' "$C_YELLOW" "$(t env_still)" "$C_RESET" " $still"; return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    printf '\n  %s%s%s\n' "$C_YELLOW" "$(t env_docker_down)" "$C_RESET"; return 1
  fi
  ensure_nvidia_container_toolkit || return 1
  printf '\n  %s%s%s\n' "$C_GREEN" "$(t env_ready)" "$C_RESET"
  return 0
}

# Back-compat name used by lifecycle/reconfig paths.
check_dependencies() {
  detect_os; ensure_path_brew; start_colima_if_needed; sevenzip_detect
  local missing="" d
  for d in $REQUIRED_DEPS; do dep_present "$d" || missing="$missing $d"; done
  command_exists docker && ! docker compose version >/dev/null 2>&1 && missing="$missing docker-compose"
  missing="$(trim "$missing")"
  [ -z "$missing" ] || install_missing_deps "$missing" || return 1
  ensure_nvidia_container_toolkit
}
