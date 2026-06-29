# ───────────────────────────── operator dashboard ─────────────────────────────
check_update_status() { UPDATE_AVAILABLE="${UPDATE_AVAILABLE:-false}"; }

# service|image|state|health for every container; cached so render is cheap.
COMP_LIST=""
collect_components() {
  COMP_LIST=""
  command_exists docker || return 0
  [ -f "$STACK_DIR/compose/docker-compose.yml" ] || return 0
  COMP_LIST="$( cd "$STACK_DIR/compose" 2>/dev/null && \
    docker compose -f docker-compose.yml ps -a --format '{{.Service}}|{{.Image}}|{{.State}}|{{.Health}}|{{.ExitCode}}' 2>/dev/null )" || COMP_LIST=""
}

# Operator table: context line, column header, one row per container. Column widths are
# computed from the data so long names (ingest-docling) / images don't shift the table.
render_components() {
  section_header "$(t sec_components)"
  [ -n "$COMP_LIST" ] || { printf '    %s(%s)%s\n' "$C_DIM" "$(t st_stopped)" "$C_RESET"; return 0; }
  local svc img st health code dot nw=4 iw=5 l
  while IFS='|' read -r svc img st health code; do
    [ -n "$svc" ] || continue
    img="${img##*/}"
    l=${#svc}; [ "$l" -gt "$nw" ] && nw="$l"
    l=${#img}; [ "$l" -gt "$iw" ] && iw="$l"
  done <<EOF
$COMP_LIST
EOF
  nw=$((nw + 1)); iw=$((iw + 1))
  printf '    %s%-3s %-*s %-*s %-9s %s%s\n' "$C_DIM" "" "$nw" "NAME" "$iw" "IMAGE" "STATE" "HEALTH" "$C_RESET"
  while IFS='|' read -r svc img st health code; do
    [ -n "$svc" ] || continue
    img="${img##*/}"      # short image + tag
    # green = running; dim = a one-shot that finished cleanly (exit 0, e.g. ollama-pull);
    # red = a real failure (non-zero exit / dead); yellow = transitional (created/restarting).
    case "$st" in
      running) dot="${C_GREEN}●${C_RESET}" ;;
      exited)  case "${code:-0}" in 0|'') dot="${C_DIM}●${C_RESET}" ;; *) dot="${C_RED}●${C_RESET}" ;; esac ;;
      dead)    dot="${C_RED}●${C_RESET}" ;;
      *)       dot="${C_YELLOW}●${C_RESET}" ;;
    esac
    [ -z "$health" ] && health="-"
    printf '    %s   %s%-*s%s %-*s %-9s %s\n' "$dot" "$C_B" "$nw" "$svc" "$C_RESET" "$iw" "$img" "$st" "$health"
  done <<EOF
$COMP_LIST
EOF
  return 0
}

# Network map: the two egress proxies + their routes.
proxy_label() {
  case "$1" in
    none) printf '%s' "$(t px_direct)" ;; tor) printf 'Tor' ;; wireguard) printf 'WireGuard' ;;
    vless) printf 'VLESS' ;; adguardvpn) printf 'AdGuard VPN' ;; tailscale) printf 'Tailscale' ;;
    *) printf '%s' "$1" ;;
  esac
}
render_netmap() {
  section_header "$(t sec_netmap)"
  printf '    %s%-13s%s %s%s%s  %s(LLM + %s)%s\n' "$C_DIM" "proxy-stack:" "$C_RESET" "$C_CYAN" "$(proxy_label "$EGRESS_STACK")" "$C_RESET" \
    "$C_DIM" "$(t d_update)" "$C_RESET"
  printf '    %s%-13s%s %s%s%s  %s(web worker)%s\n' "$C_DIM" "proxy-web:" "$C_RESET" "$C_CYAN" "$(proxy_label "$EGRESS_WEB")" "$C_RESET" "$C_DIM" "$C_RESET"
  if iso_active; then
    printf '    %s%-13s%s ⇄ WG ⇄  %s%s%s  %s(%s)%s\n' "$C_DIM" "agents:" "$C_RESET" "$C_B" "${AGENT_WG_IP:-?}" "$C_RESET" "$C_DIM" "${AGENT_PUBLIC_IP:-?}" "$C_RESET"
  fi
}

render_secrets() {
  section_header "$(t sec_secrets)"
  local sc="$C_DIM" label store="seal"
  if vault_enabled; then
    store="$(vault_role_label)"; label="$(vault_status_label)"; vault_up && sc="$C_GREEN" || sc="$C_YELLOW"
  else
    label="$(seal_status_label)"
    if seal_enabled; then if is_sealed; then sc="$C_GREEN"; else sc="$C_YELLOW"; fi; fi
  fi
  printf '    %sadmin:%s %s%s%s    %s %s%s:%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_B" "${ADMIN_USER:-admin}" "$C_RESET" \
    "$(status_dot "$sc")" "$C_DIM" "$store" "$C_RESET" "$sc" "$label" "$C_RESET"
}

header_stack() {
  clear_screen
  banner_stack
  render_context
  collect_runtime; collect_components
  render_runtime
  render_components
  render_netmap
  render_secrets
  printf '\n'
}

# ───────────────────────────── menus ─────────────────────────────
installed_menu() {
  load_config || return 1
  ensure_lang; check_update_status
  while true; do
    header_stack
    printf '  %s%s%s\n\n' "$C_B$C_CYAN" "$(t dash_manage)" "$C_RESET"
    menu_line "$(t dash_run)"  1 "$(t d_start)" 2 "$(t d_stop)" 3 "$(t d_restart)" 4 "$(t d_status)" 5 "$(t d_logs)"
    menu_line "$(t dash_data)" b "$(t d_backup)" r "$(t d_restore)" u "$(t d_update)" g "$(t d_rebuild)" a "$(t d_components)"
    menu_line "$(t dash_net)"  s "$(t d_security)" p "$(t d_proxy)" w "$(t d_watchdog)" e "$(t d_seal)" t "trust-ca" h "hosts"
    iso_active && menu_line "" f "$(t d_fleet)"
    menu_line "$(t dash_settings)" l "$(t d_lang)" '?' "$(t d_help)" q "$(t quit)"
    printf '\n%s: ' "$(t menu_choice_cmd)"
    local c=""; IFS= read -r c || exit 0
    # Accept a hotkey OR a typed command (start, stop, backup, security, …).
    case "$(trim "$c" | tr 'A-Z' 'a-z')" in
      1|start)            start_stack; pause ;;
      2|stop)             stop_stack; pause ;;
      3|restart)          restart_stack; pause ;;
      4|status)           status_stack; pause ;;
      5|logs)             logs_stack ;;
      b|backup)           backup_stack; pause ;;
      r|restore)          restore_stack; pause ;;
      u|update)           update_rebuild; pause ;;
      g|rebuild)          rebuild_only; pause ;;
      a|components|upgrade) component_manager; pause ;;
      s|security)         security_menu; pause ;;
      p|proxy|proxies)    proxy_menu; pause ;;
      w|watchdog)         watchdog_menu; pause ;;
      e|seal|unseal)      if vault_enabled; then { vault_up && seal_now || unseal_now; }; elif seal_enabled && ! is_sealed; then seal_now; else unseal_now; fi; pause ;;
      f|fleet)            iso_active && fleet_menu; pause ;;
      t|trust-ca|trustca) trust_ca; pause ;;
      h|hosts|add-hosts)  add_hosts_entries; pause ;;
      l|lang|language)    choose_lang ;;
      \?|help)            print_help; pause ;;
      q|quit|exit)        exit 0 ;;
      "")                 : ;;
      *)                  echo "$(t no_such_item)"; pause ;;
    esac
  done
}

bootstrap_menu() {
  ensure_lang; check_update_status
  while true; do
    header_install
    printf '  %s%s%s\n\n' "$C_DIM" "$(t bm_hint)" "$C_RESET"
    printf '  %s[1]%s %s\n' "$C_CYAN" "$C_RESET" "$(t bm_new)"
    printf '  %s[2]%s %s\n' "$C_CYAN" "$C_RESET" "$(t bm_restore)"
    printf '  %s[3]%s %s\n' "$C_CYAN" "$C_RESET" "$(t bm_upgrade)"
    printf '  %s[4]%s %s\n' "$C_CYAN" "$C_RESET" "$(t bm_selfupdate)"
    printf '  %s[5]%s %s\n\n' "$C_CYAN" "$C_RESET" "$(t bm_lang)"
    printf '  %s[q]%s %s\n\n' "$C_CYAN" "$C_RESET" "$(t quit)"
    printf '%s: ' "$(t menu_choice)"
    local c=""; IFS= read -r c || exit 0
    case "$(trim "$c")" in
      1) perform_install; pause ;;
      2) restore_stack; pause ;;
      3) component_manager; pause ;;
      4) self_update; pause ;;
      5) choose_lang ;;
      q|Q) exit 0 ;;
      *) echo "$(t no_such_item)"; pause ;;
    esac
  done
}

# ── component manager: toggle install/remove ──
cm_row() {
  local box="[ ]" tag=""
  [ "$2" = "true" ] && box="[x]"
  if [ "$2" != "$3" ]; then [ "$2" = "true" ] && tag="${C_GREEN}$(t cm_add)${C_RESET}" || tag="${C_RED}$(t cm_del)${C_RESET}"
  elif [ "$3" = "true" ]; then tag="${C_DIM}$(t cm_have)${C_RESET}"; fi
  printf '  %s %s[%s]%s %-22s %s\n' "$box" "$C_CYAN" "$1" "$C_RESET" "$4" "$tag"
}
component_manager() {
  load_config || { header_install; STACK_DIR="$(ask "Stack path" "$(default_stack_dir_for "$DEFAULT_STACK_NAME")")"; load_config || { echo "$(t no_env)"; return 1; }; }
  local t_owui="$ENABLE_OPENWEBUI" t_oh="$ENABLE_AGENTS" t_sx="$ENABLE_SEARCH" t_git="$ENABLE_GIT" t_qd="$ENABLE_QDRANT" t_mcp="$ENABLE_MCP"
  local o_owui="$t_owui" o_oh="$t_oh" o_sx="$t_sx" o_git="$t_git" o_qd="$t_qd" o_mcp="$t_mcp"
  while true; do
    sub_header "$(t cm_title)"
    cm_row 1 "$t_owui" "$o_owui" "Open WebUI"
    cm_row 2 "$t_oh"   "$o_oh"   "OpenHands"
    cm_row 3 "$t_sx"   "$o_sx"   "SearXNG"
    cm_row 4 "$t_git"  "$o_git"  "Forgejo (git)"
    cm_row 5 "$t_qd"   "$o_qd"   "Qdrant"
    cm_row 6 "$t_mcp"  "$o_mcp"  "MCP server"
    printf '\n%s\n%s: ' "$(t cm_hint)" "$(t menu_choice)"
    local line n; read_user_line line; line="$(trim "$line")"
    case "$line" in
      q|Q) return 0 ;; "") break ;;
      *) for n in $line; do case "$n" in
           1) [ "$t_owui" = true ] && t_owui=false || t_owui=true ;;
           2) [ "$t_oh" = true ] && t_oh=false || t_oh=true ;;
           3) [ "$t_sx" = true ] && t_sx=false || t_sx=true ;;
           4) [ "$t_git" = true ] && t_git=false || t_git=true ;;
           5) [ "$t_qd" = true ] && t_qd=false || t_qd=true ;;
           6) [ "$t_mcp" = true ] && t_mcp=false || t_mcp=true ;;
         esac; done ;;
    esac
  done
  if [ "$t_owui$t_oh$t_sx$t_git$t_qd$t_mcp" = "$o_owui$o_oh$o_sx$o_git$o_qd$o_mcp" ]; then echo "$(t cm_nochange)"; return 0; fi
  ENABLE_OPENWEBUI="$t_owui"; ENABLE_AGENTS="$t_oh"; ENABLE_SEARCH="$t_sx"; ENABLE_GIT="$t_git"; ENABLE_QDRANT="$t_qd"; ENABLE_MCP="$t_mcp"
  [ "$ENABLE_QDRANT" = "true" ] || ENABLE_MCP="false"
  set_default_domains
  confirm "$(t q_start_install)" 'Y' || return 0
  check_dependencies || return 1
  write_all_configs; build_openhands_sandbox
  compose up -d --build --remove-orphans
  prune_disabled_services; reload_caddy
}

# ── security: switch profile (within the current deploy profile) + per-toggle ──
security_menu() {
  load_config || { echo "$(t no_env)"; return 1; }
  sub_header "$(t d_security)"
  printf '  %s: %s%s%s\n' "$(t sec_q)" "$C_B" "$SECURITY_PROFILE" "$C_RESET"
  choose_security_profile
  apply_security_to_host
  save_config
}
apply_security_to_host() {
  { [ "$SEC_CIS" = "true" ] || [ "$SEC_FIREWALL" = "true" ]; } && can_use_sudo && harden_host
  [ "$SEC_CIS" = "false" ] && [ "$SEC_FIREWALL" = "false" ] && can_use_sudo && harden_host --off
  if [ "$SEC_WATCHDOG" = "true" ]; then watchdog_enable >/dev/null 2>&1; else watchdog_disable >/dev/null 2>&1; fi
  write_all_configs >/dev/null 2>&1 || true
}

# ── proxy management: enable/disable + configure each, then apply ──
proxy_menu() {
  load_config || { echo "$(t no_env)"; return 1; }
  while true; do
    sub_header "$(t px_title)"
    printf '  %s[1]%s proxy-stack  %s%s%s  %s(%s)%s\n' "$C_CYAN" "$C_RESET" "$C_B" "$(proxy_label "$EGRESS_STACK")" "$C_RESET" "$C_DIM" "$(t px_stack)" "$C_RESET"
    printf '  %s[2]%s proxy-web    %s%s%s  %s(%s)%s\n' "$C_CYAN" "$C_RESET" "$C_B" "$(proxy_label "$EGRESS_WEB")" "$C_RESET" "$C_DIM" "$(t px_web)" "$C_RESET"
    printf '  %s[3]%s %s: %s\n' "$C_CYAN" "$C_RESET" "$(t px_local_q)" "$(bool_label "$ROUTE_LOCAL_LLM")"
    printf '  %s[a]%s apply   %s[b]%s %s\n\n%s: ' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$(t m_back)" "$(t menu_choice)"
    local c; IFS= read -r c || return 0
    case "$(trim "$c")" in
      1) choose_egress_slot stack '0'; configure_egress_secrets stack ;;
      2) choose_egress_slot web '0'; configure_egress_secrets web ;;
      3) [ "$ROUTE_LOCAL_LLM" = "true" ] && ROUTE_LOCAL_LLM="false" || ROUTE_LOCAL_LLM="true" ;;
      a) compute_egress_endpoints; write_all_configs; build_openhands_sandbox; compose up -d --build --remove-orphans; prune_disabled_services; reload_caddy; return 0 ;;
      b|"") return 0 ;;
      *) : ;;
    esac
  done
}

watchdog_menu() {
  load_config || { echo "$(t no_env)"; return 1; }
  sub_header "$(t d_watchdog)"
  printf '  %s: %s%s%s\n\n' "$(t sec_wd_l)" "$C_B" "$(watchdog_state)" "$C_RESET"
  menu_line "" 1 "$(t on)" 2 "$(t off)" b "$(t m_back)"
  printf '%s: ' "$(t menu_choice)"
  local c; IFS= read -r c || return 0
  case "$(trim "$c")" in 1) watchdog_enable ;; 2) watchdog_disable ;; *) : ;; esac
}

print_help() {
  local cmd="$MGMT_NAME" w=40
  printf '%s%s%s v%s %s\n\n' "$C_B" "$PRODUCT_NAME" "$C_RESET" "$STACK_VERSION" "$STACK_CHANNEL"
  printf '  Usage: %s%s%s [command]\n  No command — interactive menu.\n\n' "$C_B" "$cmd" "$C_RESET"
  printf "    %-${w}s install (interactive)\n"  "$cmd install"
  printf "    %-${w}s install with defaults\n"  "$cmd install --defaults"
  printf "    %-${w}s start / stop / restart\n" "$cmd start|stop|restart"
  printf "    %-${w}s container status / logs\n" "$cmd status|logs [svc]"
  printf "    %-${w}s update images and rebuild\n" "$cmd update"
  printf "    %-${w}s install/remove components\n" "$cmd upgrade"
  printf "    %-${w}s backup / restore (7z)\n" "$cmd backup|restore"
  printf "    %-${w}s egress proxies\n"        "$cmd proxy"
  printf "    %-${w}s security profile\n"      "$cmd security"
  printf "    %-${w}s secrets seal / unseal\n" "$cmd seal|unseal"
  printf "    %-${w}s isolate agents on a VPS (WireGuard)\n" "$cmd agents --host IP"
  printf "    %-${w}s uninstall (data kept)\n" "$cmd uninstall"
  printf "    %-${w}s language ru|en\n"        '--lang ru|en'
  printf '\n'
}
usage() { print_help; }
