# ───────────────────────────── /etc/hosts + CA trust ─────────────────────────────
# Local profile only: map the service domains to 127.0.0.1 and trust the local CA
# so HTTPS works in the browser. Public profile uses real DNS + a public/own cert.

active_domains_list() {
  local d="$PSAI_DOMAIN"
  [ "$ENABLE_AGENTS" = "true" ] && d="$d $AGENTS_DOMAIN"
  [ "$ENABLE_GIT" = "true" ]    && d="$d $GIT_DOMAIN $GIT_SSH_HOST"
  [ "$ENABLE_QDRANT" = "true" ] && d="$d $QDRANT_DOMAIN"
  printf '%s' "$d"
}

hosts_marker() { printf '# psai:%s' "$SAFE_STACK_NAME"; }

add_hosts_entries() {
  [ "$DEPLOY_PROFILE" = "public" ] && return 0
  no_domain && return 0   # localhost ports — no /etc/hosts mapping needed
  load_config 2>/dev/null || true
  detect_os
  local marker line d; marker="$(hosts_marker)"
  line="127.0.0.1 $(active_domains_list) $marker"
  can_use_sudo || { print_hosts_command; return 0; }
  local S=""; [ "$(id -u)" = "0" ] || S="sudo"
  $S sh -c "grep -v '$marker' /etc/hosts > /etc/hosts.psai.tmp 2>/dev/null; printf '%s\n' '$line' >> /etc/hosts.psai.tmp; cat /etc/hosts.psai.tmp > /etc/hosts; rm -f /etc/hosts.psai.tmp" 2>/dev/null || true
  printf '%s%s%s\n' "$C_GREEN" "$(t done_word)" "$C_RESET"
}

print_hosts_command() {
  printf '  %s/etc/hosts:%s\n    127.0.0.1 %s %s\n' "$C_DIM" "$C_RESET" "$(active_domains_list)" "$(hosts_marker)"
}

do_trust_ca() {
  detect_os
  local crt="$STACK_DIR/secrets/certificates/root.crt"
  [ -f "$crt" ] || return 1
  case "$OS_TYPE" in
    macos) sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$crt" ;;
    linux) sudo cp "$crt" "/usr/local/share/ca-certificates/${SAFE_STACK_NAME}_root.crt" && sudo update-ca-certificates ;;
    *) return 1 ;;
  esac
}

trust_ca() {
  load_config 2>/dev/null || true
  caddy_use_acme && { printf '%s\n' "ACME — no local CA to trust."; return 0; }
  if do_trust_ca; then printf '%s%s%s\n' "$C_GREEN" "$(t done_word)" "$C_RESET"
  else print_trust_ca_command; fi
}

print_trust_ca_command() {
  detect_os
  local crt="$STACK_DIR/secrets/certificates/root.crt"
  case "$OS_TYPE" in
    macos) printf '  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain %s\n' "$crt" ;;
    linux) printf '  sudo cp %s /usr/local/share/ca-certificates/%s_root.crt && sudo update-ca-certificates\n' "$crt" "$SAFE_STACK_NAME" ;;
  esac
}

# Best-effort DNS A-record check for the public profile.
check_arecord() {
  local domain="$1" ip
  command_exists dig && ip="$(dig +short A "$domain" 2>/dev/null | head -1)"
  [ -z "${ip:-}" ] && command_exists host && ip="$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $NF; exit}')"
  [ -z "${ip:-}" ] && command_exists getent && ip="$(getent hosts "$domain" 2>/dev/null | awk '{print $1; exit}')"
  printf '%s' "${ip:-}"
}
