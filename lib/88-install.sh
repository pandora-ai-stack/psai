# ───────────────────────────── install flow (steps 0–5) ─────────────────────────────

# Optional: choose your own admin password. When set it becomes the Caddy basic-auth gate
# for the web UIs (Open WebUI/OpenHands/Qdrant) — bcrypt-hashed into the Caddyfile, the
# plaintext stored only in the secret store (the vault when sealed), never beside the config.
ask_admin_password() {
  [ "$NONINTERACTIVE" = "1" ] && return 0
  confirm "$(t admin_pw_q)" 'N' || return 0
  read_secret_confirmed ADMIN_PASSWORD_PLAIN "$(t pw_label)"
  return 0
}

# STEP 1 — node.
choose_node() {
  printf '\n%s%s%s\n' "$C_B" "$(t step1_title)" "$C_RESET"
  menu_line "$(t node_q)" s "$(t node_single)" m "$(t node_multi)"
  local c; c="$(ask "$(t node_q)" 's')"
  case "$(printf '%s' "$c" | tr -d '[][:space:]' | tr 'A-Z' 'a-z')" in
    m|multi|multiple) NODE_MODE="multi" ;;
    *)                NODE_MODE="single" ;;
  esac
  if [ "$NODE_MODE" = "multi" ]; then
    printf '  %s%s%s\n' "$C_DIM" "$(t node_multi_note)" "$C_RESET"
    printf '  %s%s%s\n' "$C_DIM" "$(t node_multi_pub)" "$C_RESET"
    DEPLOY_PROFILE="public"; ENABLE_AGENTS="true"
  fi
  prompt_set STACK_NAME "$(t q_stack_name)" "$DEFAULT_STACK_NAME"
  SAFE_STACK_NAME="$(safe_name "$STACK_NAME")"; [ -z "$SAFE_STACK_NAME" ] && SAFE_STACK_NAME="$DEFAULT_STACK_NAME"
  prompt_set STACK_DIR "$(t q_stack_dir)" "$(default_stack_dir_for "$SAFE_STACK_NAME")"
  STACK_DIR="${STACK_DIR/#\~/$HOME}"
  prompt_set ADMIN_USER "$(t q_admin_user)" "$DEFAULT_ADMIN_USER"
  ask_admin_password
  return 0   # never let a trailing non-zero abort the installer under set -e
}

# STEP 2 — deployment profile.
choose_deploy_profile() {
  if [ "$NODE_MODE" = "multi" ]; then DEPLOY_PROFILE="public"; else
    printf '\n%s%s%s\n' "$C_B" "$(t step2_title)" "$C_RESET"
    menu_line "$(t prof_q)" l "$(t prof_local)" p "$(t prof_public)"
    local c; c="$(ask "$(t prof_q)" 'l')"
    case "$(printf '%s' "$c" | tr -d '[][:space:]' | tr 'A-Z' 'a-z')" in
      p|public|pub) DEPLOY_PROFILE="public" ;;
      *)            DEPLOY_PROFILE="local" ;;
    esac
  fi
  if [ "$DEPLOY_PROFILE" = "public" ]; then ask_public_domain; fi
  return 0   # MUST end 0: under `set -e` a non-zero return here (e.g. the local-profile
             # case where the public check is false) aborts the whole installer.
}

ask_public_domain() {
  prompt_set PUBLIC_DOMAIN "$(t pub_domain_q)" ""
  if [ -z "$PUBLIC_DOMAIN" ]; then
    TLS_MODE="self"; printf '  %s%s%s\n' "$C_YELLOW" "$(t pub_noip)" "$C_RESET"; return 0
  fi
  PUBLIC_DOMAIN="$(normalize_zone "$PUBLIC_DOMAIN")"; TLS_MODE="le"
  prompt_set ACME_EMAIL "$(t pub_email)" "$ACME_EMAIL"
  # A-record reminder + best-effort check against the host IP.
  printf '  %s%s%s\n    %sai.%s  A  →  %s%s\n' "$C_DIM" "$(t pub_arecord)" "$C_RESET" "$C_DIM" "$PUBLIC_DOMAIN" "$(host_ip)" "$C_RESET"
  local got; got="$(check_arecord "psai.$PUBLIC_DOMAIN")"
  if [ -n "$got" ]; then printf '  %s%s (%s)%s\n' "$C_GREEN" "$(t pub_arecord_ok)" "$got" "$C_RESET"
  else printf '  %s%s%s\n' "$C_YELLOW" "$(t pub_arecord_no)" "$C_RESET"; fi
}

# AI section: check the hardware, then offer a bundled local LLM (Ollama) + a model that fits.
# Sets LOCAL_LLM (ollama/none) + OLLAMA_MODEL + GPU_MODE so the memory backend and chat use it.
choose_local_ai() {
  GPU_MODE="$(gpu_runtime)"
  printf '\n  %s%s%s\n' "$C_B$C_CYAN" "$(t ai_title)" "$C_RESET"
  if [ "$GPU_MODE" = "nvidia" ]; then printf '  %s%s%s\n' "$C_GREEN" "$(t ai_gpu_nvidia)" "$C_RESET"
  else
    detect_os
    [ "$OS_TYPE" = "macos" ] && printf '  %s%s%s\n' "$C_YELLOW" "$(t ai_cpu_mac)" "$C_RESET" \
                              || printf '  %s%s%s\n' "$C_YELLOW" "$(t ai_cpu_linux)" "$C_RESET"
  fi
  if ! confirm "$(t q_local_ai)" 'Y'; then LOCAL_LLM="none"; return 0; fi
  LOCAL_LLM="ollama"
  local def; def="$(gpu_default_model)"
  if confirm "$(t q_ai_model_def) $def?" 'Y'; then OLLAMA_MODEL="$def"
  else OLLAMA_MODEL="$(ask "$(t q_ai_model)" "$def")"; [ -z "$OLLAMA_MODEL" ] && OLLAMA_MODEL="$def"; fi
  printf '  %s%s%s\n' "$C_DIM" "$(t ai_pull_note)" "$C_RESET"
  return 0
}

# Force every additional/advanced component off — the answer when the operator declines extras.
extras_default_off() {
  ENABLE_QDRANT="false"; RAG_MODE="off"; ENABLE_EMBEDDINGS="false"; SHARED_MEMORY="false"
  MEMORY_MODE="none"; ENABLE_MCP="false"; LOCAL_LLM="none"
  MCP_GATEWAY="false"; LLM_GATEWAY="false"; ENABLE_EVAL="false"; ENABLE_PENTEST="false"
  return 0
}

# STEP 3 — components. Core (chat/agents/search/git) default yes; everything else lives behind
# the "additional components?" gate (default no).
choose_components() {
  printf '\n%s%s%s\n' "$C_B" "$(t step3_title)" "$C_RESET"
  confirm "$(t q_openwebui)" 'Y' && ENABLE_OPENWEBUI="true" || ENABLE_OPENWEBUI="false"
  if [ "$NODE_MODE" = "multi" ]; then ENABLE_AGENTS="true"   # agents are the point of multi-node
  else confirm "$(t q_agents)" 'Y' && ENABLE_AGENTS="true" || ENABLE_AGENTS="false"; fi
  if [ "$ENABLE_AGENTS" = "true" ]; then
    confirm "$(t q_web_oh)" 'Y' && AGENT_WEB="true" || AGENT_WEB="false"
    [ "$NODE_MODE" = "multi" ] && prompt_set OPENHANDS_LLM_MODEL "$(t q_oh_model)" "$OPENHANDS_LLM_MODEL"
  fi
  confirm "$(t q_search)" 'Y' && ENABLE_SEARCH="true" || ENABLE_SEARCH="false"
  if confirm "$(t q_git)" 'Y'; then
    ENABLE_GIT="true"; prompt_set GIT_SSH_PORT "$(t q_git_ssh_port)" "$DEFAULT_GIT_SSH_PORT"
    # multi: git lives on master OR moves to the agent worker node (one git either way).
    [ "$NODE_MODE" = "multi" ] && { confirm "$(t q_git_on_agent)" 'N' && ISOLATE_GIT="true" || ISOLATE_GIT="false"; }
  else ENABLE_GIT="false"; GIT_SSH_PORT="$DEFAULT_GIT_SSH_PORT"; fi

  # ── Additional / advanced components ──────────────────────────────────────────────
  # One gate, default OFF, so a plain install stays simple (chat + agents + search + git).
  # Yes → vector memory / RAG-plus, a memory backend + local LLM, MCP/LLM gateways, eval.
  if ! confirm "$(t q_extras)" 'N'; then extras_default_off; return 0; fi
  printf '  %s%s%s\n' "$C_B$C_CYAN" "$(t q_extras_title)" "$C_RESET"
  choose_local_ai   # AI section: hardware check → bundle Ollama + a fitting model (memory reuses it)
  # Shared vector memory.
  if [ "$NODE_MODE" = "multi" ]; then
    confirm "$(t ra_shared_q)" 'N' && { SHARED_MEMORY="true"; ENABLE_QDRANT="true"; } || SHARED_MEMORY="false"
  else
    if confirm "$(t q_qdrant)" 'N'; then
      ENABLE_QDRANT="true"
      printf '  %s%s%s\n' "$C_DIM" "$(t q_rag_plus_hint)" "$C_RESET"
      confirm "$(t q_rag_plus)" "$(rag_plus_default_answer)" && RAG_MODE="plus" || RAG_MODE="basic"
    else ENABLE_QDRANT="false"; RAG_MODE="off"; fi
  fi
  if [ "$ENABLE_QDRANT" = "true" ]; then
    # In rag-plus the local embed service handles embeddings — don't also ask for the built-in.
    [ "$RAG_MODE" = "plus" ] || { confirm "$(t q_embeddings)" 'N' && ENABLE_EMBEDDINGS="true" || ENABLE_EMBEDDINGS="false"; }
  else ENABLE_EMBEDDINGS="false"; fi
  # Memory backend (shared by chat + agents). One selector replaces the old MCP-stub toggle.
  if [ "$ENABLE_AGENTS" = "true" ] || [ "$ENABLE_OPENWEBUI" = "true" ]; then
    printf '  %s%s%s\n' "$C_DIM" "$(t q_memory_hint)" "$C_RESET"
    local mc; mc="$(ask "$(t q_memory)" "$([ "$ENABLE_QDRANT" = "true" ] && printf stub || printf none)")"
    case "$(printf '%s' "$mc" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
      cognee)   MEMORY_MODE="cognee"; ENABLE_MCP="false" ;;
      graphiti) MEMORY_MODE="graphiti"; ENABLE_MCP="false" ;;
      mem0)     MEMORY_MODE="mem0"; ENABLE_MCP="false" ;;
      stub)     if [ "$ENABLE_QDRANT" = "true" ]; then MEMORY_MODE="stub"; ENABLE_MCP="true"
                else printf '  %s%s%s\n' "$C_YELLOW" "$(t q_memory_stub_needs_qdrant)" "$C_RESET"; MEMORY_MODE="none"; ENABLE_MCP="false"; fi ;;
      *)        MEMORY_MODE="none"; ENABLE_MCP="false" ;;
    esac
    case "$MEMORY_MODE" in
      cognee|graphiti)
        # Bundle a local LLM (Ollama, no cloud key) or point at an external endpoint (LM Studio/cloud).
        if [ "$LOCAL_LLM" = "ollama" ] || confirm "$(t q_bundle_ollama)" 'Y'; then LOCAL_LLM="ollama"
        else
          printf '  %s%s%s\n' "$C_DIM" "$(t q_ext_llm_hint)" "$C_RESET"
          [ -n "$MEMORY_LLM_URL" ] || MEMORY_LLM_URL="$(ask "$(t q_memory_llm_url)" '')"
          [ -n "$MEMORY_LLM_KEY" ] || MEMORY_LLM_KEY="$(ask "$(t q_memory_llm_key)" '')"
        fi ;;
      mem0) [ -n "$MEM0_MCP_URL" ] || MEM0_MCP_URL="$(ask "$(t q_mem0_url)" '')" ;;
    esac
  else ENABLE_MCP="false"; MEMORY_MODE="none"; fi
  # Verified tool servers for the agents (Docker MCP Gateway). Needs the host socket.
  if [ "$ENABLE_AGENTS" = "true" ]; then
    printf '  %s%s%s\n' "$C_DIM" "$(t q_gateway_hint)" "$C_RESET"
    confirm "$(t q_gateway)" 'N' && MCP_GATEWAY="true" || MCP_GATEWAY="false"
    confirm "$(t q_litellm)" 'N' && LLM_GATEWAY="true" || LLM_GATEWAY="false"
    confirm "$(t q_eval)" 'N' && ENABLE_EVAL="true" || ENABLE_EVAL="false"
  else MCP_GATEWAY="false"; LLM_GATEWAY="false"; ENABLE_EVAL="false"; fi
  if confirm "$(t q_pentest)" 'N'; then printf '  %s%s%s\n' "$C_RED" "$(t pentest_warn)" "$C_RESET"; ENABLE_PENTEST="true"; else ENABLE_PENTEST="false"; fi
  return 0   # never let a trailing non-zero abort the installer under set -e
}

# STEP 5 — zone & domains. Local zone stays the default (lan); a public domain fixes the
# zone. Local deployments may skip domains entirely → services on localhost ports.
choose_zone() {
  printf '\n%s%s%s\n' "$C_B" "$(t step5_title)" "$C_RESET"
  if [ "$DEPLOY_PROFILE" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ]; then
    DOMAIN_ZONE="$PUBLIC_DOMAIN"
  else
    # Local: domains are optional. Decline → reach services on http://localhost:PORT.
    if ! confirm "$(t q_use_domains)" 'Y'; then
      NO_DOMAIN="true"; DOMAIN_ZONE="localhost"
      printf '  %s%s%s\n' "$C_DIM" "$(t dom_localhost_note)" "$C_RESET"
      set_default_domains
      print_active_domains
      return 0
    fi
    DOMAIN_ZONE="$DEFAULT_DOMAIN_ZONE"
  fi
  printf '  %s: %s%s%s\n' "$(t q_zone_def)" "$C_B" "$DOMAIN_ZONE" "$C_RESET"
  set_default_domains
  confirm_domains_loop
  if ! caddy_use_acme && [ "${TLS_MODE:-}" != "own" ]; then
    prompt_set CERT_YEARS "$(t cert_lifetime)" "$DEFAULT_CERT_YEARS"
    printf '%s' "$CERT_YEARS" | grep -Eq '^[0-9]+$' || CERT_YEARS="$DEFAULT_CERT_YEARS"
  else CERT_YEARS="$DEFAULT_CERT_YEARS"; fi
  return 0   # never let a trailing non-zero abort the installer under set -e
}

show_summary() {
  printf '\n%s%s%s\n' "$C_B" "$(t sum_header)" "$C_RESET"
  printf '  %-14s %s\n' "$(t sum_name):"    "$STACK_NAME"
  printf '  %-14s %s\n' "$(t sum_dir):"     "$STACK_DIR"
  printf '  %-14s %s\n' "$(t sum_node):"    "$NODE_MODE"
  printf '  %-14s %s\n' "$(t sum_profile):" "$DEPLOY_PROFILE"
  printf '  %-14s %s\n' "$(t sec_q):"       "$SECURITY_PROFILE"
  printf '  %-14s %s\n' "$(t sum_zone):"    "$DOMAIN_ZONE"
  printf '  %-14s %s · %s · %s · %s · %s · %s\n' "Components:" \
    "OpenWebUI=$(bool_label "$ENABLE_OPENWEBUI")" "OpenHands=$(bool_label "$ENABLE_AGENTS")" \
    "Search=$(bool_label "$ENABLE_SEARCH")" "Git=$(bool_label "$ENABLE_GIT")" \
    "Qdrant=$(bool_label "$ENABLE_QDRANT")" "MCP=$(bool_label "$ENABLE_MCP")"
  [ "${RAG_MODE:-off}" != "off" ] && printf '  %-14s %s\n' "RAG:" "$RAG_MODE"
  case "${MEMORY_MODE:-stub}" in stub|none) : ;; *) printf '  %-14s %s\n' "Memory:" "$MEMORY_MODE" ;; esac
  [ "${LOCAL_LLM:-none}" = "ollama" ] && printf '  %-14s ollama (%s)\n' "LLM:" "$OLLAMA_MODEL"
  [ "${MCP_GATEWAY:-false}" = "true" ] && printf '  %-14s %s\n' "MCP gateway:" "$MCP_GATEWAY_SERVERS"
  { [ "${LLM_GATEWAY:-false}" = "true" ] || [ "${ENABLE_EVAL:-false}" = "true" ]; } && \
    printf '  %-14s %s%s\n' "Ops:" "$([ "$LLM_GATEWAY" = true ] && printf 'LiteLLM ')" "$([ "$ENABLE_EVAL" = true ] && printf 'Langfuse')"
  printf '  %-14s stack=%s  web=%s\n' "Proxies:" "$EGRESS_STACK" "$EGRESS_WEB"
  print_active_domains
  printf '\n'
}

install_prompt_flow() {
  # The prompt phase is pure UI — it collects input and sets variables, it does not write
  # files or touch docker. `set -Eeuo pipefail` (armed globally) is unforgiving here: any
  # menu/preview helper whose last statement is a `cond && cmd` (false on the common path)
  # returns non-zero and, called as a bare command, aborts the whole installer mid-prompt.
  # Disable errexit for the collection, re-arm it before the real install work begins.
  set +e
  header_install
  step0_env || { printf '%s\n' "$(t install_cancel)"; set -e; exit 1; }   # STEP 0
  choose_node                 # STEP 1
  choose_deploy_profile       # STEP 2
  choose_components           # STEP 3
  choose_security_profile     # STEP 4
  choose_zone                 # STEP 5
  ask_proxies                 # two egress proxies (default direct)
  show_summary
  set -e                      # re-arm before perform_install does the real work
  confirm "$(t q_start_install)" 'Y' || { echo "$(t install_cancel)"; exit 0; }
}

apply_defaults_noninteractive() {
  STACK_NAME="${STACK_NAME:-$DEFAULT_STACK_NAME}"
  SAFE_STACK_NAME="$(safe_name "$STACK_NAME")"; [ -z "$SAFE_STACK_NAME" ] && SAFE_STACK_NAME="$DEFAULT_STACK_NAME"
  STACK_DIR="${STACK_DIR:-$(default_stack_dir_for "$SAFE_STACK_NAME")}"; STACK_DIR="${STACK_DIR/#\~/$HOME}"
  ADMIN_USER="${ADMIN_USER:-$DEFAULT_ADMIN_USER}"
  # `install --defaults` = a COMPLETE LOCAL stack: NO security profile, EVERY component on,
  # reachable both by the .lan domains AND on localhost ports. Each value still honours an
  # explicit PSAI_* override (so the multi-node agent install, which sets them, is unaffected).
  if [ "$NODE_MODE" != "multi" ]; then
    DEPLOY_PROFILE="${PSAI_DEPLOY:-local}"
    SECURITY_PROFILE="${PSAI_PROFILE:-none}"
    ENABLE_OPENWEBUI="${PSAI_OPENWEBUI:-true}"; ENABLE_AGENTS="${PSAI_AGENTS:-true}"
    ENABLE_SEARCH="${PSAI_SEARCH:-true}"; ENABLE_GIT="${PSAI_GIT:-true}"
    RAG_MODE="${PSAI_RAG:-plus}"; MEMORY_MODE="${PSAI_MEMORY:-cognee}"; LOCAL_LLM="${PSAI_LLM:-ollama}"
    OLLAMA_MODEL="${PSAI_OLLAMA_MODEL:-$(gpu_default_model)}"   # platform-aware local default
    MCP_GATEWAY="${PSAI_MCP_GATEWAY:-true}"; LLM_GATEWAY="${PSAI_LLM_GATEWAY:-true}"; ENABLE_EVAL="${PSAI_EVAL:-true}"
    [ "$DEPLOY_PROFILE" = "local" ] && DUAL_ACCESS="${PSAI_DUAL:-true}"
  fi
  [ "$NODE_MODE" = "multi" ] && { DEPLOY_PROFILE="public"; ENABLE_AGENTS="true"; }
  resolve_security_profile
  GIT_SSH_PORT="${GIT_SSH_PORT:-$DEFAULT_GIT_SSH_PORT}"
  if [ "$DEPLOY_PROFILE" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ]; then DOMAIN_ZONE="$PUBLIC_DOMAIN"; else DOMAIN_ZONE="${DOMAIN_ZONE:-$DEFAULT_DOMAIN_ZONE}"; fi
  [ -z "${PUBLIC_DOMAIN:-}" ] && [ "$DEPLOY_PROFILE" = "public" ] && TLS_MODE="self"
  set_default_domains
  CERT_YEARS="${CERT_YEARS:-$DEFAULT_CERT_YEARS}"
  compute_egress_endpoints
}

perform_install() {
  if [ "$NONINTERACTIVE" = "1" ] || [ "$ASSUME_DEFAULTS" = "1" ]; then
    NONINTERACTIVE="1"; apply_defaults_noninteractive
    check_dependencies || return 1
  else
    install_prompt_flow
  fi

  resolve_oh_mode   # public/multi → dind unless PSAI_OH_MODE pinned (persisted by write_all_configs)
  resolve_rag_mode  # PSAI_RAG=plus → Qdrant + local embeddings/reranker + Docling/Tika ingest
  resolve_local_llm    # PSAI_LLM=ollama → bundle a local LLM; point memory at it
  resolve_memory_mode  # PSAI_MEMORY=cognee/graphiti/mem0 → real memory backend (replaces the stub)
  if [ "${MCP_GATEWAY:-false}" = "true" ] && [ "$DEPLOY_PROFILE" = "public" ]; then
    printf '%s%s%s\n' "$C_YELLOW" "$(t gateway_public_warn)" "$C_RESET"
  fi
  if [ "${ENABLE_AGENTS:-false}" = "true" ] && [ "${AGENTS_DOCKER:-false}" = "true" ] && [ "$DEPLOY_PROFILE" = "public" ]; then
    printf '%s%s%s\n' "$C_YELLOW" "$(t agents_docker_public_warn)" "$C_RESET"
  fi
  if ollama_enabled && [ "$DEPLOY_PROFILE" = "public" ]; then
    printf '%s%s%s\n' "$C_YELLOW" "$(t ollama_auth_proxy_warn)" "$C_RESET"
  fi
  capture_docker_context   # pin the docker daemon (Colima vs Docker Desktop) for later runs

  detect_os
  [ "$OS_TYPE" = "macos" ] && printf '\n%s%s%s\n' "$C_YELLOW" "$(t mac_admin_note)" "$C_RESET"

  if [ -f "$STACK_DIR/.stack.env" ] && [ "$NONINTERACTIVE" != "1" ]; then
    printf '\n'; confirm "$(t q_overwrite)" 'Y' || exit 0
  fi

  # Unseal stack-vault BEFORE any secret is generated, so nothing plaintext hits disk.
  # Run in the foreground (it may prompt for the passphrase) — not inside run_step.
  if vault_enabled; then
    mkdir -p "$STACK_DIR/bin" "$STACK_DIR/data/logs"
    vault_present || build_vault || true
    vault_start || { printf '%svault required but not unsealed — aborting%s\n' "$C_RED" "$C_RESET"; return 1; }
  fi

  if ingest_enabled; then STEP_TOTAL=6; else STEP_TOTAL=5; fi
  STEP_NUM=0
  run_step "$(t step_dirs)"     prepare_dirs_and_secrets
  run_step "$(t step_configs)"  write_all_configs
  run_step "$(t step_sandbox)"  build_openhands_sandbox
  run_step "$(t step_compose)"  validate_compose

  # /etc/hosts (local profile).
  if [ "$DEPLOY_PROFILE" != "public" ]; then
    if can_use_sudo; then
      [ "$NONINTERACTIVE" = "1" ] || confirm "$(t q_add_hosts)" 'Y' && add_hosts_entries
    else print_hosts_command; fi
  fi

  run_step "$(t step_up)" compose_up_core
  if ingest_enabled; then
    if ! run_step "$(t step_ingest)" compose_up_ingest; then
      printf '%s%s%s\n' "$C_YELLOW" "$(t ingest_deferred)" "$C_RESET" >&2
    fi
  fi
  prune_disabled_services

  # Apply the security profile to the host. Firewall + CIS hardening need admin. If we don't
  # have it, say so loudly instead of leaving the saved profile (SEC_FIREWALL=true) claiming a
  # firewall that was never enabled — and verify it actually came up when we did try.
  if [ "$SEC_CIS" = "true" ] || [ "$SEC_FIREWALL" = "true" ]; then
    if can_use_sudo; then
      harden_host
      if [ "$SEC_FIREWALL" = "true" ] && [ "$(firewall_status)" != "on" ]; then
        printf '%s%s sudo %s harden%s\n' "$C_YELLOW" "$(t harden_fw_pending)" "$MGMT_NAME" "$C_RESET"
      fi
    else
      printf '%s%s sudo %s harden%s\n' "$C_YELLOW" "$(t harden_no_admin)" "$MGMT_NAME" "$C_RESET"
    fi
  fi
  [ "$SEC_WATCHDOG" = "true" ] && watchdog_enable >/dev/null 2>&1

  # Trust the local CA when we can (so HTTPS just works).
  CA_TRUSTED="false"
  if ! caddy_use_acme && can_use_sudo; then
    do_trust_ca >/dev/null 2>&1 && CA_TRUSTED="true"
  fi

  # Multi-node: provision the agent worker node(s) now that the master is up.
  if [ "$NODE_MODE" = "multi" ] && [ "$NONINTERACTIVE" != "1" ] && type remote_agents >/dev/null 2>&1; then
    remote_agents || true
  fi

  finish_message
}

finish_message() {
  local mgmt="$STACK_DIR/bin/$MGMT_NAME"
  printf '\n'; banner_stack
  printf '\n%s%s %s%s\n' "$C_B" "$C_GREEN" "$(t fin_done)" "$C_RESET"
  line
  printf '  %s:\n    %s%s%s %s\n    %s%s%s\n' "$(t fin_manage)" \
    "$C_B" "$MGMT_NAME" "$C_RESET" "$(t fin_cmd_hint)" "$C_DIM" "$mgmt" "$C_RESET"
  printf '%s' "$MGMT_NAME" | copy_to_clipboard 2>/dev/null && printf '    %s↑ copied%s\n' "$C_DIM" "$C_RESET"
  printf '  %s:\n    %s/secrets/passwords.txt\n' "$(t fin_secrets)" "$STACK_DIR"
  if ! caddy_use_acme && ! no_domain; then printf '  %s:\n    %s/secrets/certificates/root.crt\n' "$(t fin_ca)" "$STACK_DIR"; fi
  if [ "${SEAL_ENABLED:-false}" = "true" ]; then
    printf '  %s: %s%s%s (%s)\n' "$(t d_seal)" "$C_GREEN" "$(seal_status_label)" "$C_RESET" "$SEAL_MODE"
  fi
  line
  printf '  %s:\n' "$(t fin_next)"
  if no_domain; then
    printf '    1. %s%s%s\n' "$C_GREEN" "$(t dom_localhost_note)" "$C_RESET"
    print_active_domains
    return 0
  fi
  if [ "$CA_TRUSTED" = "true" ] || caddy_use_acme; then printf '    1. %sroot CA ok%s\n' "$C_GREEN" "$C_RESET"
  else printf '    1. trust root.crt:\n'; print_trust_ca_command; fi
  printf '    2. %s  →  https://%s\n' "$(t fin_open)" "$(main_host)"
  [ "$ENABLE_GIT" = "true" ] && printf '    3. %s%s%s  →  https://%s\n' "$C_YELLOW" "$(t fin_git_note)" "$C_RESET" "$GIT_DOMAIN"
  return 0   # never let a trailing false test make a successful install report failure
}
