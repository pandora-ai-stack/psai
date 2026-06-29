# ───────────────────────────── lifecycle ─────────────────────────────
# Multi-node helpers (no-ops unless agents are isolated).
iso_active() { [ "${ISOLATE_AGENTS:-false}" = "true" ]; }
iso_vps2_ssh() {
  local k="$STACK_DIR/secrets/wg/mgmt.key"; [ -f "$k" ] || return 1
  # Pin the agent's host key on first contact (persisted known_hosts) rather than
  # StrictHostKeyChecking=no, which trusted any key on every connect.
  ssh -i "$k" -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$(ra_known_hosts)" "${RA_USER:-root}@$(agent_wg_ip)" "$@"
}
iso_wg_up()   { detect_os; [ "$OS_TYPE" = "linux" ] || return 0; local S=""; [ "$(id -u)" = 0 ] || S=sudo; $S wg-quick up wg0 2>/dev/null || true; }
iso_wg_down() { detect_os; [ "$OS_TYPE" = "linux" ] || return 0; local S=""; [ "$(id -u)" = 0 ] || S=sudo; $S wg-quick down wg0 2>/dev/null || true; }

start_stack() {
  load_config || exit 1; ensure_path_brew
  if vault_enabled; then vault_start || return 1; else ensure_unsealed || return 1; fi
  render_runtime_env   # re-render secret env from the vault (shredded on last stop)
  start_colima_if_needed
  iso_active && iso_wg_up
  iso_active && vault_enabled && vault_kms_start   # serve agent unseal keys over WG
  compose up -d
  if iso_active; then iso_vps2_ssh "$MGMT_NAME start" >/dev/null 2>&1 || printf '%sagent worker node unreachable%s\n' "$C_YELLOW" "$C_RESET"; fi
}
stop_stack() {
  load_config || exit 1; ensure_path_brew
  iso_active && { iso_vps2_ssh "$MGMT_NAME stop" >/dev/null 2>&1 || true; }
  compose stop
  shred_runtime_env   # remove the rendered secret env from disk
  if vault_enabled; then vault_kms_stop; vault_seal; elif seal_enabled && ! is_sealed; then seal_wipe; fi
  iso_active && iso_wg_down
}
status_stack()  { load_config || exit 1; ensure_path_brew; compose ps; }
restart_stack() { load_config || exit 1; ensure_path_brew; compose restart; }
logs_stack()    { load_config || exit 1; ensure_path_brew; local svc="${1:-}"; if [ -n "$svc" ]; then compose logs -f --tail=200 "$svc"; else compose logs -f --tail=200; fi; }

uninstall_stack() {
  load_config || { echo "$(t no_env)"; return 1; }
  ensure_path_brew
  printf '\n%s%s%s\n  %s\n' "$C_RED$C_B" "$(t un_warn)" "$C_RESET" "$STACK_DIR"
  confirm "$(t un_confirm)" 'N' || { echo "$(t cancelled)"; return 0; }
  local rmvol=""; confirm "$(t q_rm_volumes)" 'N' && rmvol="-v"
  # shellcheck disable=SC2086
  compose down $rmvol --remove-orphans >/dev/null 2>&1 || true
  vault_seal   # stop the secrets daemon (wipes its RAM)
  docker rm -f "${SAFE_STACK_NAME}-wg-bridge" >/dev/null 2>&1 || true
  remove_legacy_command_links
  local d; for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    [ -L "$d/$MGMT_NAME" ] && rm -f "$d/$MGMT_NAME" 2>/dev/null || true
  done
  cron_remove >/dev/null 2>&1 || true
  watchdog_disable >/dev/null 2>&1 || true
  rm -f "$(seal_keyfile)" 2>/dev/null || true
  if confirm "$(t un_data)" 'N'; then rm -rf "$STACK_DIR" 2>/dev/null || true; printf '%s%s%s\n' "$C_GREEN" "$(t un_done)" "$C_RESET"
  else printf '%s %s%s%s\n' "$(t un_kept)" "$C_B" "$STACK_DIR" "$C_RESET"; fi
}

update_rebuild() {
  load_config || exit 1; ensure_path_brew; start_colima_if_needed
  check_dependencies || return 1
  select_openhands_image
  write_all_configs
  build_openhands_sandbox
  compose_up_core
  if ingest_enabled; then compose_up_ingest || printf '%s%s%s\n' "$C_YELLOW" "$(t ingest_deferred)" "$C_RESET" >&2; fi
  prune_disabled_services
}
rebuild_only() {
  load_config || exit 1; ensure_path_brew; start_colima_if_needed
  select_openhands_image
  write_all_configs
  build_openhands_sandbox
  compose_up_core
  if ingest_enabled; then compose_up_ingest || printf '%s%s%s\n' "$C_YELLOW" "$(t ingest_deferred)" "$C_RESET" >&2; fi
  prune_disabled_services
}
