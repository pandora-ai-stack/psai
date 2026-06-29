# ───────────────────────────── watchdog daemon ─────────────────────────────
# Tiny health watchdog: every couple of minutes it checks the stack and brings any
# stopped container back up. Scheduled via launchd (macOS) or cron (Linux).
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-120}"   # seconds

write_watchdog_script() {
  local f="$STACK_DIR/bin/watchdog.sh"
  mkdir -p "$STACK_DIR/bin" "$STACK_DIR/data/logs"
  cat > "$f" <<EOF
#!/usr/bin/env bash
# Auto-generated stack health watchdog.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\$PATH"
LOG="$STACK_DIR/data/logs/watchdog.log"
cd "$STACK_DIR/compose" 2>/dev/null || exit 0
command -v colima >/dev/null 2>&1 && { docker info >/dev/null 2>&1 || colima start >/dev/null 2>&1 || true; }
# No auto-unseal: the watchdog only restarts existing containers (their env was
# rendered at the last start). If the vault is sealed it does not re-render secrets.
DC=(docker compose -f docker-compose.yml)
bad="\$("\${DC[@]}" ps -a --format '{{.Service}}={{.State}}' 2>/dev/null | grep -v '=running\$' || true)"
if [ -n "\$bad" ]; then
  echo "\$(date '+%F %T') unhealthy -> up -d : \$bad" >> "\$LOG"
  "\${DC[@]}" up -d >/dev/null 2>&1 || true
fi
EOF
  chmod +x "$f"
  printf '%s' "$f"
}

watchdog_label() { printf 'com.psai.%s.watchdog' "$SAFE_STACK_NAME"; }
watchdog_plist() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(watchdog_label)"; }

watchdog_enable() {
  load_config || { echo "$(t no_env)"; return 1; }
  local f; f="$(write_watchdog_script)"; detect_os
  case "$OS_TYPE" in
    macos)
      local plist; plist="$(watchdog_plist)"; mkdir -p "$HOME/Library/LaunchAgents"
      cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$(watchdog_label)</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$f</string></array>
  <key>StartInterval</key><integer>$WATCHDOG_INTERVAL</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
      launchctl unload "$plist" 2>/dev/null || true
      launchctl load "$plist" 2>/dev/null || true ;;
    linux)
      local every=$(( WATCHDOG_INTERVAL / 60 )); [ "$every" -lt 1 ] && every=1
      ( crontab -l 2>/dev/null | grep -v "psai-watchdog:${SAFE_STACK_NAME}"; \
        printf '*/%s * * * * %s # psai-watchdog:%s\n' "$every" "$f" "$SAFE_STACK_NAME" ) | crontab - ;;
    *) echo 'Watchdog unsupported on this OS.'; return 1 ;;
  esac
  SEC_WATCHDOG="true"; save_config 2>/dev/null || true
  printf '%s%s%s\n' "$C_GREEN" "$(t done_word)" "$C_RESET"
}

watchdog_disable() {
  load_config || { echo "$(t no_env)"; return 1; }
  detect_os
  case "$OS_TYPE" in
    macos) local plist; plist="$(watchdog_plist)"; launchctl unload "$plist" 2>/dev/null || true; rm -f "$plist" ;;
    linux) crontab -l 2>/dev/null | grep -v "psai-watchdog:${SAFE_STACK_NAME}" | crontab - 2>/dev/null || true ;;
  esac
  SEC_WATCHDOG="false"; save_config 2>/dev/null || true
  printf '%s%s%s\n' "$C_GREEN" "$(t done_word)" "$C_RESET"
}

watchdog_state() {
  detect_os
  case "$OS_TYPE" in
    macos) launchctl list 2>/dev/null | grep -q "$(watchdog_label)" && printf '%s' "$(t st_running)" || printf '%s' "$(t st_stopped)" ;;
    linux) crontab -l 2>/dev/null | grep -q "psai-watchdog:${SAFE_STACK_NAME}" && printf '%s' "$(t st_running)" || printf '%s' "$(t st_stopped)" ;;
    *) printf '%s' "$(t st_stopped)" ;;
  esac
}
