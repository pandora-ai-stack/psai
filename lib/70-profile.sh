# ───────────────────────────── security profile ─────────────────────────────
# strict / default / none. Each capability (SEC_*) is individually toggleable here
# and from the dashboard later. choose_security_profile() picks a profile, shows the
# resolved defaults, then offers "apply defaults" or "configure manually".

is_public_or_multi() { [ "$DEPLOY_PROFILE" = "public" ] || [ "$NODE_MODE" = "multi" ]; }

# OS gating for the hardening capabilities. Some are Linux-only: the CIS kernel sysctls +
# sshd hardening + unattended-upgrades, fail2ban, TPM auto-unseal (tpm2-tools), and the
# WG-only-SSH lockdown. macOS applies only the cross-platform set — the secrets vault, the
# application firewall (socketfilterfw), and the watchdog (launchd). So on macOS the
# Linux-only rows are hidden from the preview/tuner and forced off, instead of showing as a
# misleading "off" that would never take effect.
sec_os()    { detect_os 2>/dev/null || true; printf '%s' "${OS_TYPE:-}"; }
sec_linux() { [ "$(sec_os)" = "linux" ]; }
cis_applies()   { sec_linux; }
# Disabling public SSH is MULTI-ONLY (master reaches agents over WG, so the WG channel
# survives) and Linux-only. On a single host there is no WG fallback — dropping SSH would
# be a lockout — so we never offer it there.
nossh_applies() { [ "$NODE_MODE" = "multi" ] && sec_linux; }
f2b_applies()   { [ "$DEPLOY_PROFILE" = "public" ] && sec_linux; }
# TPM auto-unseal only makes sense when the vault is on (it seals the passphrase) and needs
# tpm2-tools — Linux only (macOS Secure Enclave would need a native helper).
tpm_applies()   { [ "$SEC_SEAL" = "true" ] && sec_linux; }

# Secrets have exactly two modes: SEC_SEAL=false → plaintext .env on disk; SEC_SEAL=true
# → stack-vault (secrets in the daemon's RAM, MANUAL passphrase on every start, nothing
# stored but the AES-GCM blob). There is no auto-unseal. Only strict turns the vault on.
resolve_security_profile() {
  # TPM auto-unseal is opt-in; seed from the env, preserve across profile switches.
  SEC_TPM="${SEC_TPM:-${VAULT_TPM:-false}}"
  case "$SECURITY_PROFILE" in
    strict)
      SEC_SEAL="true"; SEC_FIREWALL="true"; SEC_WATCHDOG="true"
      cis_applies   && SEC_CIS="true"      || SEC_CIS="false"
      nossh_applies && SEC_NOSSH="true"    || SEC_NOSSH="false"
      f2b_applies   && SEC_FAIL2BAN="true" || SEC_FAIL2BAN="false" ;;
    none)
      SEC_SEAL="false"; SEC_CIS="false"; SEC_FIREWALL="false"
      SEC_WATCHDOG="false"; SEC_NOSSH="false"; SEC_FAIL2BAN="false"; SEC_TPM="false" ;;
    *)  # default — secrets in plaintext .env (no vault)
      SECURITY_PROFILE="default"
      SEC_SEAL="false"; SEC_FIREWALL="false"; SEC_WATCHDOG="false"
      cis_applies && SEC_CIS="true" || SEC_CIS="false"
      SEC_NOSSH="false"; SEC_FAIL2BAN="false" ;;
  esac
  tpm_applies || SEC_TPM="false"   # no vault / not Linux → no TPM seal
  apply_security_bindings
}

# Map the SEC_* toggles onto the concrete runtime flags consumed elsewhere.
apply_security_bindings() {
  SEAL_ENABLED="$SEC_SEAL"   # legacy alias; the vault is the only encryption path
  SEAL_MODE="manual"          # the only mode — no auto-unseal
  ENABLE_FAIL2BAN="$SEC_FAIL2BAN"
  VAULT_TPM="${SEC_TPM:-false}"   # TPM auto-unseal (consumed by vault_start)
  # If TPM was turned off, drop any seal blob so the vault reverts to manual unseal.
  [ "${SEC_TPM:-false}" = "true" ] || { type tpm_forget >/dev/null 2>&1 && tpm_forget; }
}

# One row of the preview: "● label  on/off".
sec_row() {
  local on="$1" label="$2" dot="$C_GREEN" val
  [ "$on" = "true" ] && val="$(t on)" || { dot="$C_DIM"; val="$(t off)"; }
  printf '    %s %-26s %s%s%s\n' "$(status_dot "$dot")" "$label" "$dot" "$val" "$C_RESET"
}

security_preview() {
  printf '\n  %s%s%s\n' "$C_B$C_CYAN" "$(t sec_preview)" "$C_RESET"
  printf '    %s %-26s %s%s%s\n' "$(status_dot "$C_GREEN")" "Container hardening" "$C_GREEN" "$(t on)" "$C_RESET"
  local seal_lbl
  if [ "$SEC_SEAL" = "true" ]; then seal_lbl="$(t sec_seal_l) — stack-vault (manual)"; else seal_lbl="$(t sec_seal_l) — .env"; fi
  sec_row "$SEC_SEAL"     "$seal_lbl"
  tpm_applies   && sec_row "$SEC_TPM"  "$(t sec_tpm_l)"
  cis_applies   && sec_row "$SEC_CIS"  "$(t sec_cis_l)"
  sec_row "$SEC_FIREWALL" "$(t sec_fw_l)"
  sec_row "$SEC_WATCHDOG" "$(t sec_wd_l)"
  nossh_applies && sec_row "$SEC_NOSSH"  "$(t sec_nossh_l)"
  f2b_applies   && sec_row "$SEC_FAIL2BAN" "$(t sec_f2b_l)"
  sec_linux || printf '    %s%s%s\n' "$C_DIM" "$(t sec_macos_note)" "$C_RESET"
  return 0   # the trailing `cond && …` may be false → keep this function returning 0 so it
             # never aborts callers running under `set -e`.
}

# Manual tuning: toggle capabilities by number, Enter to apply.
security_tune() {
  while true; do
    security_preview
    printf '\n'
    if cis_applies; then menu_line "" 1 "$(t sec_seal_l)" 2 "$(t sec_cis_l)" 3 "$(t sec_fw_l)" 4 "$(t sec_wd_l)"
    else                 menu_line "" 1 "$(t sec_seal_l)" 3 "$(t sec_fw_l)" 4 "$(t sec_wd_l)"; fi
    { nossh_applies || f2b_applies; } && menu_line "" 5 "$(t sec_nossh_l)" 6 "$(t sec_f2b_l)"
    tpm_applies && menu_line "" 7 "$(t sec_tpm_l)"
    printf '  %s%s%s\n%s: ' "$C_DIM" "$(t sec_toggle_hint)" "$C_RESET" "$(t menu_choice)"
    local line n; read_user_line line; line="$(trim "$line")"
    [ -z "$line" ] && break
    for n in $line; do
      case "$n" in
        1) [ "$SEC_SEAL" = "true" ] && SEC_SEAL="false" || SEC_SEAL="true" ;;
        2) cis_applies && { [ "$SEC_CIS" = "true" ] && SEC_CIS="false" || SEC_CIS="true"; } ;;
        3) [ "$SEC_FIREWALL" = "true" ] && SEC_FIREWALL="false" || SEC_FIREWALL="true" ;;
        4) [ "$SEC_WATCHDOG" = "true" ] && SEC_WATCHDOG="false" || SEC_WATCHDOG="true" ;;
        5) nossh_applies && { [ "$SEC_NOSSH" = "true" ] && SEC_NOSSH="false" || SEC_NOSSH="true"; } ;;
        6) f2b_applies   && { [ "$SEC_FAIL2BAN" = "true" ] && SEC_FAIL2BAN="false" || SEC_FAIL2BAN="true"; } ;;
        7) tpm_applies   && { [ "$SEC_TPM" = "true" ] && SEC_TPM="false" || SEC_TPM="true"; } ;;
        *) : ;;
      esac
    done
    tpm_applies || SEC_TPM="false"   # turning the vault off also drops TPM
    apply_security_bindings
  done
}

# Vault mode needs a passphrase (prompted on every start). Collect it once at install.
ask_seal_pass() {
  [ "$SEC_SEAL" = "true" ] || return 0
  [ "$NONINTERACTIVE" = "1" ] && return 0
  printf '  %s%s%s\n' "$C_DIM" "$(t vault_passhint)" "$C_RESET"
  read_secret_confirmed SEAL_PASS_PLAIN "$(t vault_pass)"
  return 0
}

# Step 4 entry: pick profile (one line), preview, then apply or tune.
choose_security_profile() {
  menu_line "$(t sec_q)" s "$(t sec_strict)" d "$(t sec_default)" n "$(t sec_none)"
  printf '    %s[s]%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$(t sec_strict_d)"  "$C_RESET"
  printf '    %s[d]%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$(t sec_default_d)" "$C_RESET"
  printf '    %s[n]%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$(t sec_none_d)"    "$C_RESET"
  local c; c="$(ask "$(t sec_q)" 'd')"
  case "$(printf '%s' "$c" | tr -d '[][:space:]' | tr 'A-Z' 'a-z')" in
    s|strict) SECURITY_PROFILE="strict" ;;
    n|none)   SECURITY_PROFILE="none" ;;
    *)        SECURITY_PROFILE="default" ;;
  esac
  resolve_security_profile
  security_preview
  printf '\n'
  menu_line "" a "$(t sec_apply)" c "$(t sec_tune)"
  local d; d="$(ask "$(t menu_choice)" 'a')"
  case "$(printf '%s' "$d" | tr -d '[][:space:]' | tr 'A-Z' 'a-z')" in
    c|tune|manual) security_tune ;;
    *) : ;;
  esac
  ask_seal_pass
  return 0   # never let a trailing non-zero abort the installer under set -e
}
