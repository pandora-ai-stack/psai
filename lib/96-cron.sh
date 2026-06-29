# ───────────────────────────── cron / self-update / checks ─────────────────────────────
# Docker image auto-update (weekly): pull + recreate changed containers.
cron_marker() { printf 'psai-autoupdate:%s' "$SAFE_STACK_NAME"; }

cron_install() {
  load_config || { echo "$(t no_env)"; return 1; }
  detect_os
  local cmd="$STACK_DIR/bin/$MGMT_NAME update"
  case "$OS_TYPE" in
    linux) ( crontab -l 2>/dev/null | grep -v "$(cron_marker)"; printf '0 4 * * 0 %s >/dev/null 2>&1 # %s\n' "$cmd" "$(cron_marker)" ) | crontab - ;;
    macos) ( crontab -l 2>/dev/null | grep -v "$(cron_marker)"; printf '0 4 * * 0 %s >/dev/null 2>&1 # %s\n' "$cmd" "$(cron_marker)" ) | crontab - 2>/dev/null || true ;;
  esac
  printf '%s%s%s\n' "$C_GREEN" "$(t done_word)" "$C_RESET"
}
cron_remove() {
  load_config 2>/dev/null || true
  crontab -l 2>/dev/null | grep -v "$(cron_marker)" | crontab - 2>/dev/null || true
  printf '%s%s%s\n' "$C_GREEN" "$(t done_word)" "$C_RESET"
}

# Pull the latest installer from the public RAW url (when configured) and replace
# the in-stack copy. No-op with a clear note until REPO_RAW_URL is filled.
sha256_of() { ( shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" ) | awk '{print $1}'; }

self_update() {
  [ -n "${REPO_RAW_URL:-}" ] || { printf 'self-update: REPO_RAW_URL not set (fill it for the public release).\n'; return 0; }
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$REPO_RAW_URL" -o "$tmp" || { echo 'download failed'; rm -f "$tmp"; return 1; }
  bash -n "$tmp" || { echo 'downloaded file failed syntax check'; rm -f "$tmp"; return 1; }

  # Verify against versions.json. The signed manifest is the trust anchor: the sha256
  # lives IN versions.json, so it only means something once the manifest's SSH
  # signature checks out against the PINNED public key. A pubkey fetched (or a sha256
  # taken) from the same place as the payload proves nothing, and `bash -n` is only a
  # SYNTAX check — neither proves authenticity. So a signature anchor is MANDATORY for
  # any applied update: refuse outright unless BOTH the manifest URL and the pinned key
  # are configured (fail closed), then require a valid signature below.
  if [ -z "${REPO_VERSIONS_URL:-}" ] || [ -z "${UPDATE_SIGN_PUBKEY:-}" ]; then
    printf '%sself-update: signature trust anchor not configured (need REPO_VERSIONS_URL + pinned UPDATE_SIGN_PUBKEY) — refusing%s\n' "$C_RED" "$C_RESET"
    rm -f "$tmp"; return 1
  fi
  if [ -n "${REPO_VERSIONS_URL:-}" ]; then
    command_exists ssh-keygen || { echo 'ssh-keygen required to verify the signed manifest — install openssh'; rm -f "$tmp"; return 1; }
    local vjson sig allow; vjson="$(mktemp)"; sig="$(mktemp)"; allow="$(mktemp)"
    curl -fsSL "$REPO_VERSIONS_URL" -o "$vjson" || { echo 'versions.json download failed'; rm -f "$tmp" "$vjson" "$sig" "$allow"; return 1; }
    curl -fsSL "$REPO_VERSIONS_URL.sig" -o "$sig" || { echo 'versions.json.sig download failed'; rm -f "$tmp" "$vjson" "$sig" "$allow"; return 1; }
    # Verify the SSH signature (ssh-keygen -Y) against the PINNED public key. The signed
    # manifest is the trust anchor; the installer_sha256 inside it is only trusted once this
    # passes. Fail closed on any mismatch.
    printf '%s %s\n' "${UPDATE_SIGN_ID:-psai}" "$UPDATE_SIGN_PUBKEY" > "$allow"
    if ! ssh-keygen -Y verify -f "$allow" -I "${UPDATE_SIGN_ID:-psai}" -n "${UPDATE_SIGN_NS:-psai-versions}" -s "$sig" < "$vjson" >/dev/null 2>&1; then
      printf '%sself-update: versions.json signature INVALID — aborting%s\n' "$C_RED" "$C_RESET"; rm -f "$tmp" "$vjson" "$sig" "$allow"; return 1
    fi
    rm -f "$sig" "$allow"
    local want got; want="$(sed -n 's/.*"installer_sha256": *"\([a-f0-9]*\)".*/\1/p' "$vjson" | head -1)"
    got="$(sha256_of "$tmp")"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      printf '%sself-update: sha256 mismatch — aborting%s\n' "$C_RED" "$C_RESET"; rm -f "$tmp" "$vjson"; return 1
    fi
    rm -f "$vjson"
  fi

  if load_config 2>/dev/null && [ -d "$STACK_DIR/bin" ]; then cp "$tmp" "$STACK_DIR/bin/$MGMT_NAME"; chmod +x "$STACK_DIR/bin/$MGMT_NAME"; fi
  rm -f "$tmp"; printf '%s%s%s\n' "$C_GREEN" "$(t done_word)" "$C_RESET"
}

# ── diagnostics ──
health_check() {
  load_config || { echo "$(t no_env)"; return 1; }
  ensure_path_brew; collect_components
  printf '%s\n' "${COMP_LIST:-no containers}"
}
install_check() {
  load_config || { echo "$(t no_env)"; return 1; }
  printf 'stack:    %s\n' "$STACK_DIR"
  printf 'compose:  %s\n' "$([ -f "$STACK_DIR/compose/docker-compose.yml" ] && echo ok || echo missing)"
  printf 'caddy:    %s\n' "$([ -f "$STACK_DIR/compose/Caddyfile" ] && echo ok || echo missing)"
  printf 'secrets:  %s\n' "$([ -f "$STACK_DIR/secrets/passwords.txt" ] || seal_enabled && echo ok || echo missing)"
}
security_check() {
  load_config || { echo "$(t no_env)"; return 1; }
  printf 'profile:   %s\n' "$SECURITY_PROFILE"
  printf 'seal:      %s (%s)\n' "$(seal_status_label)" "$SEAL_MODE"
  local fw; fw="$(firewall_status)"
  # Flag the gap between intent and reality: the profile asked for a firewall but it isn't
  # actually up (e.g. install ran without admin) — so the status doesn't quietly look fine.
  if [ "${SEC_FIREWALL:-false}" = "true" ] && [ "$fw" != "on" ]; then
    printf 'firewall:  %s  (profile wants ON — run: sudo %s harden)\n' "$fw" "$MGMT_NAME"
  else
    printf 'firewall:  %s\n' "$fw"
  fi
  printf 'watchdog:  %s\n' "$(watchdog_state)"
}
