# ───────────────────────────── main ─────────────────────────────
main() {
  detect_os
  ensure_path_brew
  case "${1:-}" in --lang) UI_LANG="${2:-}"; LANG_FROM_ENV="1"; shift 2 || true ;; esac
  load_lang

  case "${1:-}" in
    install)
      shift || true
      case "${1:-}" in --defaults|-y|--yes) ASSUME_DEFAULTS="1"; NONINTERACTIVE="1" ;; esac
      ensure_lang; perform_install ;;
    start)      start_stack ;;
    stop)       stop_stack ;;
    status)     status_stack ;;
    restart)    restart_stack ;;
    logs)       shift || true; logs_stack "${1:-}" ;;
    update)     ensure_lang; update_rebuild ;;
    rebuild)    ensure_lang; rebuild_only ;;
    upgrade)    ensure_lang; component_manager ;;
    backup)     shift || true; ensure_lang; backup_stack "$@" ;;
    restore)    shift || true; ensure_lang; restore_stack "$@" ;;
    proxy|egress)   ensure_lang; load_config && proxy_menu ;;
    security)   ensure_lang; load_config && security_menu ;;
    seal)       ensure_lang; seal_now ;;
    unseal)     ensure_lang; unseal_now ;;
    watchdog)     ensure_lang; watchdog_menu ;;
    watchdog-on)  ensure_lang; watchdog_enable ;;
    watchdog-off) ensure_lang; watchdog_disable ;;
    harden)       shift || true; ensure_lang; load_config 2>/dev/null; harden_host "${1:-}" ;;
    trust-ca)     ensure_lang; trust_ca ;;
    add-hosts)    load_config || exit 1; ensure_lang; add_hosts_entries ;;
    cron-install) ensure_lang; cron_install ;;
    cron-remove)  ensure_lang; cron_remove ;;
    self-update)  ensure_lang; self_update ;;
    uninstall)    ensure_lang; uninstall_stack ;;
    agents|isolate-agents|remote-agents) shift || true; ensure_lang; remote_agents "$@" ;;
    rekey)        shift || true; ensure_lang; load_config && ra_rekey "$@" ;;
    kms-node)     shift || true; ensure_lang; load_config && ra_install_kms_node "$@" ;;
    state|collect-state) shift || true; ensure_lang; load_config && ra_collect_state "$@" ;;
    fleet)        ensure_lang; load_config && fleet_menu ;;
    health|--health)                 ensure_lang; health_check ;;
    check-install|--check-install)   ensure_lang; install_check ;;
    check-security|--check-security) ensure_lang; security_check ;;
    help|-h|--help)  ensure_lang; print_help ;;
    --version|-v)    echo "$STACK_VERSION $STACK_CHANNEL ($STACK_VERSION_TAG)" ;;
    "")
      if load_config >/dev/null 2>&1; then installed_menu; else bootstrap_menu; fi ;;
    *) usage; exit 1 ;;
  esac
}

# Run only when executed directly (allows sourcing for tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
