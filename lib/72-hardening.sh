# ───────────────────────────── host hardening ─────────────────────────────
# Firewall + CIS/CISA kernel sysctls + unattended security upgrades + conservative
# sshd hardening. Fully reversible (`psai harden --off`). The firewall ALWAYS
# allows the live SSH port before enabling, so it can never lock you out. Password
# SSH auth is left untouched.

harden_sudo() { if [ "$(id -u)" = "0" ]; then printf ''; else printf 'sudo'; fi; }

current_ssh_port() {
  local p; p="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $4}')"
  [ -n "$p" ] || p="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)"
  [ -n "$p" ] || p=22
  printf '%s' "$p"
}

firewall_status() {
  detect_os
  case "$OS_TYPE" in
    linux) command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qiE 'Status: active' && printf 'on' || printf 'off' ;;
    macos) /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -qiE 'enabled' && printf 'on' || printf 'off' ;;
    *) printf 'off' ;;
  esac
}

# CIS/CISA kernel sysctl baseline (shared by local harden + agent-server hardening).
# ip_forward is intentionally left alone — Docker needs it.
cis_sysctl_lines() {
  cat <<'EOF'
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.log_martians=1
kernel.randomize_va_space=2
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
kernel.yama.ptrace_scope=1
EOF
}
# Strict-only: fully block ptrace (even for root) so nobody can inject code into the
# stack-vault process and read its secrets. ptrace_scope=3 is irreversible until reboot
# and disables ALL debugging, so it's opt-in via the strict firewall step, not the
# default CIS baseline (which uses level 1).
ptrace_lockdown_lines() { printf 'kernel.yama.ptrace_scope=3\n'; }
cis_sshd_lines() {
  cat <<'EOF'
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
}

harden_linux() {
  local S sshp gitp; S="$(harden_sudo)"; sshp="$(current_ssh_port)"; gitp="${GIT_SSH_PORT:-2222}"
  # CIS sysctls + sshd hardening + unattended-upgrades (the "default" baseline).
  cis_sysctl_lines | $S tee /etc/sysctl.d/99-psai.conf >/dev/null
  $S sysctl --system >/dev/null 2>&1 || true
  $S apt-get install -y -qq unattended-upgrades >/dev/null 2>&1 || true
  $S tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  # Optional: fully block ptrace (even root) to protect the vault from code injection.
  if [ "${VAULT_PTRACE_LOCKDOWN:-false}" = "true" ]; then
    ptrace_lockdown_lines | $S tee /etc/sysctl.d/99-psai-ptrace.conf >/dev/null
    $S sysctl --system >/dev/null 2>&1 || true
  fi
  $S mkdir -p /etc/ssh/sshd_config.d
  cis_sshd_lines | $S tee /etc/ssh/sshd_config.d/99-psai.conf >/dev/null
  $S systemctl reload ssh 2>/dev/null || $S systemctl reload sshd 2>/dev/null || true
  # Firewall (strict only): ALLOW the live SSH + stack ports BEFORE enabling.
  if [ "${SEC_FIREWALL:-false}" = "true" ]; then
    command -v ufw >/dev/null 2>&1 || { $S apt-get update -qq >/dev/null 2>&1; $S apt-get install -y -qq ufw >/dev/null 2>&1; }
    $S ufw allow "${sshp}/tcp" >/dev/null 2>&1 || true
    $S ufw allow 80/tcp  >/dev/null 2>&1 || true
    $S ufw allow 443/tcp >/dev/null 2>&1 || true
    [ "${ENABLE_GIT:-false}" = "true" ] && $S ufw allow "${gitp}/tcp" >/dev/null 2>&1 || true
    $S ufw default deny incoming  >/dev/null 2>&1 || true
    $S ufw default allow outgoing >/dev/null 2>&1 || true
    $S ufw --force enable >/dev/null 2>&1 || true
  fi
}

harden_macos() {
  [ "${SEC_FIREWALL:-false}" = "true" ] || return 0
  local S fw; S="$(harden_sudo)"; fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  $S "$fw" --setglobalstate on    >/dev/null 2>&1 || true
  $S "$fw" --setstealthmode on    >/dev/null 2>&1 || true
  $S "$fw" --setallowsigned on    >/dev/null 2>&1 || true
  $S "$fw" --setallowsignedapp on >/dev/null 2>&1 || true
}

harden_off() {
  detect_os; local S; S="$(harden_sudo)"
  case "$OS_TYPE" in
    linux) $S ufw --force disable >/dev/null 2>&1 || true
           $S rm -f /etc/sysctl.d/99-psai.conf /etc/ssh/sshd_config.d/99-psai.conf
           $S systemctl reload ssh 2>/dev/null || $S systemctl reload sshd 2>/dev/null || true ;;
    macos) local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
           $S "$fw" --setstealthmode off >/dev/null 2>&1 || true
           $S "$fw" --setglobalstate off >/dev/null 2>&1 || true ;;
  esac
}

# Entry point (CLI / install / dashboard). Applies whatever SEC_* flags are set.
harden_host() {
  load_config 2>/dev/null || true
  detect_os
  case "${1:-}" in --off|off|disable) harden_off; printf '%s\n' "$(t done_word)"; return 0 ;; esac
  [ "${SEC_CIS:-false}" = "true" ] || [ "${SEC_FIREWALL:-false}" = "true" ] || return 0
  if ! can_use_sudo; then printf '%s%s%s\n' "$C_YELLOW" "$(t env_need_admin)" "$C_RESET"; return 0; fi
  case "$OS_TYPE" in
    linux) harden_linux ;;
    macos) harden_macos ;;
    *) return 0 ;;
  esac
  printf '%s%s%s\n' "$C_GREEN" "$(t done_word)" "$C_RESET"
}
