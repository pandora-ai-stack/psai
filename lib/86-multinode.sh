# ─────────────────────────── multi-node (master + isolated agents) ───────────────────────────
# master_node_0 (WG .1) is the control plane: centralized management + state
# collection over a WireGuard-only SSH tunnel. Each agent_worker_<N> (WG .{2+N}) runs
# an OpenHands-only stack with its own SearXNG + proxy-web egress, reachable only
# inside WireGuard; web access is opt-in. The master pulls the agent's data home and
# can share its Qdrant (vector memory) with the agents over WG.
master_wg_ip()  { printf '%s.1' "$REMOTE_WG_NET"; }
agent_wg_ip()   { printf '%s.%s' "$REMOTE_WG_NET" "$(( 2 + ${AGENT_INDEX:-0} ))"; }
kms_wg_ip()     { printf '%s' "${PSAI_KMS_WG:-${REMOTE_WG_NET}.254}"; }   # external KMS node
master_label()  { printf 'master_node_0'; }
agent_label()   { printf 'agent_worker_%s' "${1:-${AGENT_INDEX:-0}}"; }

RA_KEY="" RA_PASSFILE="" RA_MODE="install" RA_OPEN_MIN=""

# Persist SSH host keys (trust-on-first-use). With UserKnownHostsFile=/dev/null,
# `accept-new` had nothing to compare against on the next connect, so every reconnect
# blindly trusted whatever key answered — no protection if a key changed under us. A
# per-stack known_hosts pins the host key on first contact and verifies it after. The
# WG paths used StrictHostKeyChecking=no (silently accept anything) — also raised to
# accept-new so a changed agent key is refused.
ra_known_hosts() {
  local d="${STACK_DIR:-$HOME/.psai}/secrets"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s/known_hosts' "$d"
}
ra_ssh() {
  local h="$RA_USER@$RA_HOST" kh; kh="$(ra_known_hosts)"
  if [ -n "$RA_KEY" ]; then ssh -i "$RA_KEY" -p "$RA_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "$h" "$@"
  else sshpass -f "$RA_PASSFILE" ssh -p "$RA_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "$h" "$@"; fi
}
ra_scp() {
  local kh; kh="$(ra_known_hosts)"
  if [ -n "$RA_KEY" ]; then scp -O -i "$RA_KEY" -P "$RA_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "$1" "$RA_USER@$RA_HOST:$2"
  else sshpass -f "$RA_PASSFILE" scp -O -P "$RA_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "$1" "$RA_USER@$RA_HOST:$2"; fi
}
ra_wg_ssh() {
  local h kh; h="$RA_USER@$(agent_wg_ip)"; kh="$(ra_known_hosts)"
  if [ -n "$RA_KEY" ]; then ssh -i "$RA_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "$h" "$@"
  else sshpass -f "$RA_PASSFILE" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "$h" "$@"; fi
}

ensure_sshpass() {
  command_exists sshpass && return 0
  [ -n "$RA_KEY" ] && return 0
  detect_os
  case "$OS_TYPE" in
    macos) brew install hudochenkov/sshpass/sshpass >/dev/null 2>&1 || brew install sshpass >/dev/null 2>&1 ;;
    linux) local S=""; [ "$(id -u)" = 0 ] || S="sudo"; $S apt-get install -y -qq sshpass >/dev/null 2>&1 ;;
  esac
  command_exists sshpass
}

ra_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) RA_HOST="$2"; shift 2 ;;
      --port) RA_PORT="$2"; shift 2 ;;
      --user) RA_USER="$2"; shift 2 ;;
      --key)  RA_KEY="${2/#\~/$HOME}"; shift 2 ;;
      --open-ssh) RA_MODE="open-ssh"; RA_OPEN_MIN="${2:-}"; case "$RA_OPEN_MIN" in ''|*[!0-9]*) RA_OPEN_MIN=""; shift ;; *) shift 2 ;; esac ;;
      --domain) AGENT_DOMAIN="$2"; shift 2 ;;
      --email)  AGENT_ACME_EMAIL="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$RA_HOST" ] || RA_HOST="$(ask "$(t ra_host)" '')"
  [ -n "$RA_HOST" ] || return 1
  RA_PORT="${RA_PORT:-22}"; RA_USER="${RA_USER:-root}"
  if [ -z "$RA_KEY" ]; then
    RA_PASSFILE="$(mktemp)"; chmod 600 "$RA_PASSFILE"
    printf '%s: ' "$(t ra_pass)"; stty -echo 2>/dev/null; IFS= read -r _p || true; stty echo 2>/dev/null; printf '\n'
    printf '%s' "$_p" > "$RA_PASSFILE"; unset _p
  fi
  return 0
}

# "Server matches and is ready" — check the agent host can run the stack.
ra_check_requirements() {
  printf '%s...\n' "$(t ra_check)"
  local rep; rep="$(ra_ssh 'set -e
  os=$(uname -s)
  mem=$(awk "/MemTotal/{print int(\$2/1024)}" /proc/meminfo 2>/dev/null || echo 0)
  disk=$(df -m / | awk "NR==2{print \$4}")
  apt=$(command -v apt-get >/dev/null 2>&1 && echo yes || echo no)
  dock=$(command -v docker >/dev/null 2>&1 && echo yes || echo no)
  echo "$os|$mem|$disk|$apt|$dock"' 2>/dev/null)" || return 1
  local os mem disk apt dock; IFS='|' read -r os mem disk apt dock <<EOF
$rep
EOF
  [ "$os" = "Linux" ] || return 1
  [ "${mem:-0}" -ge 1500 ] 2>/dev/null || return 1
  [ "${disk:-0}" -ge 8000 ] 2>/dev/null || return 1
  [ "$apt" = "yes" ] || [ "$dock" = "yes" ] || return 1
  printf '  %s%s%s  (RAM %sMB · disk %sMB)\n' "$C_GREEN" "$(t ra_check_ok)" "$C_RESET" "$mem" "$disk"
  return 0
}

remote_agents() {
  load_config || { echo "$(t no_env)"; return 1; }
  ensure_path_brew
  ra_parse_args "$@" || { echo "$(t ra_host)"; return 1; }
  ensure_sshpass || { echo "$(t ra_sshpass_need)"; rm -f "$RA_PASSFILE"; return 1; }
  if [ "$RA_MODE" = "open-ssh" ]; then ra_open_ssh; rm -f "$RA_PASSFILE"; return $?; fi

  printf '%s...\n' "$(t ra_connect)"
  ra_ssh 'echo ok' >/dev/null 2>&1 || { echo "$(t ra_ssh_fail)"; rm -f "$RA_PASSFILE"; return 1; }
  ra_check_requirements || { echo "$(t ra_check_fail)"; rm -f "$RA_PASSFILE"; return 1; }
  ra_collect_options

  # Install Docker on the agent from Docker's official apt repo with a pinned signed-by GPG
  # key (apt verifies packages) — not `curl get.docker.com | sh` (arbitrary unverified code).
  ra_ssh 'set -e
if ! command -v docker >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker 2>/dev/null || true
docker --version' >/dev/null 2>&1 || { echo "$(t ra_docker_fail)"; rm -f "$RA_PASSFILE"; return 1; }

  # KMS: when the master runs the vault, the agent runs one too — unsealed by the
  # KMS over WG. Generate the agent's key (K, the vault passphrase) + auth token (T)
  # in the keys store (master vault, or the external KMS node) BEFORE installing, so
  # the agent's vault.enc is encrypted with K; the key never lands on the agent's disk.
  local agent_vault="false" K="" T=""
  if vault_enabled; then
    agent_vault="true"
    if [ -n "${KMS_HOST:-}" ]; then
      K="$(random_secret)"; printf '%s' "$K" | kms_store_put "agent_unseal_${AGENT_INDEX}"
      T="$(random_secret)"; printf '%s' "$T" | kms_store_put "kms_token_${AGENT_INDEX}"
    else
      K="$(secret_get agent_unseal_${AGENT_INDEX} random_secret)"
      T="$(secret_get kms_token_${AGENT_INDEX} random_secret)"
    fi
    ra_ship_vault_src
  fi

  printf '%s...\n' "$(t ra_install)"
  ra_scp "$SCRIPT_PATH" "/root/${MGMT_NAME}.sh"
  local oh_git="false"; [ "$ISOLATE_GIT" = "true" ] && oh_git="true"
  # The agent is a lean OpenHands node — explicitly turn the new advanced components OFF so the
  # everything-on `install --defaults` doesn't bloat it (each PSAI_* override wins in apply_defaults).
  local renv="PSAI_LANG=${UI_LANG:-en} PSAI_NODE_MODE=single PSAI_OPENWEBUI=false PSAI_AGENTS=true PSAI_SEARCH=true \
PSAI_GIT=$oh_git PSAI_QDRANT=false PSAI_EGRESS_WEB='$AGENT_EGRESS' PSAI_WEB_VIA_PROXY=true \
PSAI_RAG=off PSAI_MEMORY=none PSAI_LLM=none PSAI_MCP_GATEWAY=false PSAI_LLM_GATEWAY=false PSAI_EVAL=false PSAI_DUAL=false"
  if [ "$agent_vault" = "true" ]; then
    # The vault passphrase K is passed on STDIN, not in the command line: PSAI_VAULT_PASS=$(cat)
    # is evaluated on the agent, so K never appears in the agent's argv / `ps` / environ
    # listing. (Earlier this inlined PSAI_VAULT_PASS='$K', exposing it to any local user.)
    renv="$renv PSAI_PROFILE=strict PSAI_VAULT_PASS=\$(cat) PSAI_VAULT_SRC=\$HOME/vault-src"
  else
    renv="$renv PSAI_PROFILE=default"
  fi
  if [ "$AGENT_WEB" = "true" ] && [ -n "$AGENT_DOMAIN" ]; then
    renv="$renv PSAI_DEPLOY=public PSAI_PUBLIC_DOMAIN='$AGENT_DOMAIN' PSAI_ACME_EMAIL='$AGENT_ACME_EMAIL'"
  else
    renv="$renv PSAI_DEPLOY=local"
  fi
  if [ "$agent_vault" = "true" ]; then
    printf '%s' "$K" | ra_ssh "$renv bash /root/${MGMT_NAME}.sh install --defaults" || { echo "$(t ra_agent_fail)"; rm -f "$RA_PASSFILE"; return 1; }
  else
    ra_ssh "$renv bash /root/${MGMT_NAME}.sh install --defaults" </dev/null || { echo "$(t ra_agent_fail)"; rm -f "$RA_PASSFILE"; return 1; }
  fi

  setup_wg_tunnel || { echo "$(t ra_wg_fail)"; rm -f "$RA_PASSFILE"; return 1; }
  ra_install_mgmt_key
  [ "$SHARED_MEMORY" = "true" ] && start_qdrant_wg_bridge
  [ "$agent_vault" = "true" ] && ra_setup_kms "$T"
  ra_harden_vps2
  ra_install_failback
  ra_lockdown_public_ssh

  ISOLATE_AGENTS="true"; AGENT_PUBLIC_IP="$RA_HOST"; AGENT_WG_IP="$(agent_wg_ip)"
  [ "$ISOLATE_GIT" = "true" ] && ENABLE_GIT="false"
  ra_register_agent
  save_config 2>/dev/null || true
  printf '%s%s%s\n' "$C_GREEN" "$(t ra_done)" "$C_RESET"
  ra_print_endpoints
  rm -f "$RA_PASSFILE"
}

ra_collect_options() {
  [ -n "$AGENT_EGRESS" ] || AGENT_EGRESS="tor"
  if [ "$AGENT_WEB" = "true" ]; then
    [ -n "$AGENT_DOMAIN" ] || AGENT_DOMAIN="$(ask "$(t q_agent_domain)" '')"
    if [ -n "$AGENT_DOMAIN" ]; then
      AGENT_DOMAIN="$(normalize_zone "$AGENT_DOMAIN")"
      printf '  %s%s%s\n    %s%s.%s  A  →  %s%s\n' "$C_DIM" "$(t pub_arecord)" "$C_RESET" "$C_DIM" "$AGENT_SUB" "$AGENT_DOMAIN" "$RA_HOST" "$C_RESET"
      [ -n "$AGENT_ACME_EMAIL" ] || AGENT_ACME_EMAIL="$(ask "$(t pub_email)" "$ACME_EMAIL")"
    else AGENT_WEB="false"; fi
  fi
}

ra_register_agent() {
  local entry kept; entry="${AGENT_INDEX}:${RA_HOST}:$(agent_wg_ip):${AGENT_DOMAIN:-}"
  # shellcheck disable=SC2086
  kept="$(printf '%s\n' $AGENT_SERVERS | grep -v "^${AGENT_INDEX}:" 2>/dev/null | tr '\n' ' ')"
  AGENT_SERVERS="$(printf '%s %s' "$kept" "$entry" | tr -s ' ' | sed 's/^ //;s/ $//')"
}

ra_print_endpoints() {
  local awg; awg="$(agent_wg_ip)"
  printf '  %s %s  ⇄  WireGuard  ⇄  %s %s\n' "$(master_label)" "$(master_wg_ip)" "$(agent_label)" "$awg"
  printf '  public: %s%s%s   wg: %s%s%s (ssh %s@%s)\n' "$C_B" "$RA_HOST" "$C_RESET" "$C_B" "$awg" "$C_RESET" "$RA_USER" "$awg"
  if [ "$AGENT_WEB" = "true" ] && [ -n "$AGENT_DOMAIN" ]; then printf '  agents: https://%s.%s\n' "$AGENT_SUB" "$AGENT_DOMAIN"
  else printf '  agents: %shttp://%s:3000%s (WG only)\n' "$C_B" "$awg" "$C_RESET"; fi
}

setup_wg_tunnel() {
  printf '%s...\n' "WireGuard"
  command_exists wg || { detect_os; case "$OS_TYPE" in macos) brew install wireguard-tools >/dev/null 2>&1 ;; linux) { [ "$(id -u)" = 0 ] || S=sudo; }; ${S:-} apt-get install -y -qq wireguard-tools >/dev/null 2>&1 ;; esac; }
  command_exists wg || return 1
  ra_ssh 'command -v wg >/dev/null 2>&1 || (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard wireguard-tools) >/dev/null 2>&1; command -v wg >/dev/null 2>&1' || return 1
  local wgdir="$STACK_DIR/secrets/wg"; mkdir -p "$wgdir"; chmod 700 "$wgdir"
  local m_priv m_pub a_priv a_pub m_ep mwg awg
  mwg="$(master_wg_ip)"; awg="$(agent_wg_ip)"
  m_priv="$(cat "$wgdir/master.key" 2>/dev/null)"; [ -n "$m_priv" ] || { m_priv="$(wg genkey)"; ( umask 077; printf '%s' "$m_priv" > "$wgdir/master.key" ); }
  m_pub="$(printf '%s' "$m_priv" | wg pubkey)"
  a_priv="$(ra_ssh 'cat /etc/wireguard/agent.key 2>/dev/null || { k=$(wg genkey); umask 077; printf %s "$k" > /etc/wireguard/agent.key; printf %s "$k"; }')"
  a_pub="$(printf '%s' "$a_priv" | wg pubkey)"
  m_ep="$(ask "$(t q_master_ep)" "$(host_ip)")"
  ra_ssh "mkdir -p /etc/wireguard; cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${awg}/24
PrivateKey = ${a_priv}
[Peer]
PublicKey = ${m_pub}
Endpoint = ${m_ep}:${REMOTE_WG_PORT}
AllowedIPs = ${REMOTE_WG_NET}.0/24
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf; wg-quick down wg0 2>/dev/null; wg-quick up wg0 2>/dev/null; systemctl enable wg-quick@wg0 2>/dev/null || true" || return 1
  cat > "$wgdir/wg0.conf" <<EOF
[Interface]
Address = ${mwg}/24
PrivateKey = ${m_priv}
ListenPort = ${REMOTE_WG_PORT}
[Peer]
PublicKey = ${a_pub}
AllowedIPs = ${awg}/32
PersistentKeepalive = 25
EOF
  chmod 600 "$wgdir/wg0.conf"
  detect_os
  if [ "$OS_TYPE" = "linux" ]; then
    local S=""; [ "$(id -u)" = 0 ] || S=sudo
    $S cp "$wgdir/wg0.conf" /etc/wireguard/wg0.conf
    $S wg-quick down wg0 2>/dev/null; $S wg-quick up wg0 2>/dev/null; $S systemctl enable wg-quick@wg0 2>/dev/null || true
  else
    printf '  %smacOS: bring the master tunnel up via WireGuard.app / wg-quick%s\n' "$C_YELLOW" "$C_RESET"
  fi
}

# Peer an external KMS node into the fleet WireGuard at .254 (hub-and-spoke: master is
# the hub). The master gets a route to the KMS (to populate the keys store); IP
# forwarding on the master lets agents (spokes) reach the KMS (spoke) through it. The
# KMS peer is APPENDED to the master conf so it doesn't clobber agent peers.
# FIRST CUT — needs a 3-host (master + agent + KMS) live test.
setup_wg_kms_tunnel() {
  printf '%s (KMS node)...\n' "WireGuard"
  command_exists wg || { detect_os; case "$OS_TYPE" in macos) brew install wireguard-tools >/dev/null 2>&1 ;; linux) { [ "$(id -u)" = 0 ] || S=sudo; }; ${S:-} apt-get install -y -qq wireguard-tools >/dev/null 2>&1 ;; esac; }
  command_exists wg || return 1
  ra_ssh 'command -v wg >/dev/null 2>&1 || (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard wireguard-tools) >/dev/null 2>&1; command -v wg >/dev/null 2>&1' || return 1
  local wgdir="$STACK_DIR/secrets/wg"; mkdir -p "$wgdir"; chmod 700 "$wgdir"
  local m_priv m_pub k_priv k_pub m_ep mwg kwg
  mwg="$(master_wg_ip)"; kwg="$(kms_wg_ip)"
  m_priv="$(cat "$wgdir/master.key" 2>/dev/null)"; [ -n "$m_priv" ] || { m_priv="$(wg genkey)"; ( umask 077; printf '%s' "$m_priv" > "$wgdir/master.key" ); }
  m_pub="$(printf '%s' "$m_priv" | wg pubkey)"
  k_priv="$(ra_ssh 'cat /etc/wireguard/kms.key 2>/dev/null || { k=$(wg genkey); umask 077; printf %s "$k" > /etc/wireguard/kms.key; printf %s "$k"; }')"
  k_pub="$(printf '%s' "$k_priv" | wg pubkey)"
  m_ep="$(ask "$(t q_master_ep_kms)" "$(host_ip)")"
  # KMS node tunnel: master as peer, full subnet so it can reach (and be reached by) agents.
  ra_ssh "mkdir -p /etc/wireguard; cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${kwg}/24
PrivateKey = ${k_priv}
[Peer]
PublicKey = ${m_pub}
Endpoint = ${m_ep}:${REMOTE_WG_PORT}
AllowedIPs = ${REMOTE_WG_NET}.0/24
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf; wg-quick down wg0 2>/dev/null; wg-quick up wg0 2>/dev/null; systemctl enable wg-quick@wg0 2>/dev/null || true" || return 1
  # Append the KMS as a peer to the master conf (idempotent; keeps existing agent peers).
  if ! grep -q "$k_pub" "$wgdir/wg0.conf" 2>/dev/null; then
    cat >> "$wgdir/wg0.conf" <<EOF
[Peer]
PublicKey = ${k_pub}
AllowedIPs = ${kwg}/32
PersistentKeepalive = 25
EOF
  fi
  detect_os
  if [ "$OS_TYPE" = "linux" ]; then
    local S=""; [ "$(id -u)" = 0 ] || S=sudo
    $S sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true   # hub forwarding for spoke<->spoke
    $S cp "$wgdir/wg0.conf" /etc/wireguard/wg0.conf
    $S wg-quick down wg0 2>/dev/null; $S wg-quick up wg0 2>/dev/null || true
  else
    printf '  %smacOS master: re-apply wg0 to add the KMS peer%s\n' "$C_YELLOW" "$C_RESET"
  fi
}

ra_install_mgmt_key() {
  local kf="$STACK_DIR/secrets/wg/mgmt.key"
  mkdir -p "$STACK_DIR/secrets/wg"; chmod 700 "$STACK_DIR/secrets/wg"
  [ -f "$kf" ] || ssh-keygen -t ed25519 -N '' -f "$kf" -C "psai-mgmt-${SAFE_STACK_NAME}" >/dev/null 2>&1 || return 0
  local pub; pub="$(cat "$kf.pub" 2>/dev/null)"; [ -n "$pub" ] || return 0
  ra_ssh "mkdir -p ~/.ssh; chmod 700 ~/.ssh; grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' '$pub' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" >/dev/null 2>&1 || true
}

# Publish the master's Qdrant onto the WG address so agents share one vector store.
start_qdrant_wg_bridge() {
  [ "$ENABLE_QDRANT" = "true" ] || return 0
  docker rm -f "${SAFE_STACK_NAME}-wg-bridge" >/dev/null 2>&1 || true
  local net; net="$(docker network ls --format '{{.Name}}' | grep -E "${SAFE_STACK_NAME}.*default" | head -1)"
  [ -n "$net" ] || return 0
  docker run -d --name "${SAFE_STACK_NAME}-wg-bridge" --restart unless-stopped \
    --network "$net" "$ALPINE_IMAGE" sh -c \
    'apk add --no-cache socat >/dev/null 2>&1; socat TCP-LISTEN:6333,fork,reuseaddr TCP:qdrant:6333' >/dev/null 2>&1 || true
}

# Ship the stack-vault source to the agent so it can build its own (per-arch) binary.
# Small (Cargo.toml + main.rs); a prebuilt per-arch binary in the release is the
# production path (see PLAN).
ra_ship_vault_src() {
  local src=""
  for d in "$SCRIPT_DIR/vault" "$SCRIPT_DIR/../vault"; do [ -f "$d/Cargo.toml" ] && { src="$d"; break; }; done
  [ -n "$src" ] || return 0
  # Prefer a matching prebuilt for the agent's arch — ship it straight to bin/ so the
  # agent needs no Rust toolchain (build_vault then sees it present and skips building).
  local aarch tag pre; aarch="$(ra_ssh 'uname -m' 2>/dev/null | tr -d '[:space:]')"
  case "$aarch" in x86_64|amd64) tag=x86_64 ;; aarch64|arm64) tag=aarch64 ;; *) tag="$aarch" ;; esac
  pre="$src/dist/stack-vault-linux-$tag"
  if [ -x "$pre" ]; then
    ra_ssh 'mkdir -p ~/psai/bin' >/dev/null 2>&1 || true
    ra_scp "$pre" 'psai/bin/stack-vault'
    ra_ssh 'chmod +x ~/psai/bin/stack-vault' >/dev/null 2>&1 || true
    printf '  %sshipped prebuilt stack-vault (linux-%s)%s\n' "$C_DIM" "$tag" "$C_RESET"
  fi
  # Always ship source too as a fallback (used only if no prebuilt was placed).
  ra_ssh 'mkdir -p ~/vault-src/src' >/dev/null 2>&1 || true
  # scp remote paths are relative to the remote home, so no '~/' needed.
  ra_scp "$src/Cargo.toml" 'vault-src/Cargo.toml'
  ra_scp "$src/src/main.rs" 'vault-src/src/main.rs'
}

# Configure the agent to unseal from the KMS (master, or an external KMS node when
# PSAI_KMS_HOST is set): write secrets/kms.conf (token only — the key never lands here),
# register the agent's hardware fingerprint in the keys store (so a disk clone on other
# hardware is refused), start the local KMS unless an external node owns it, open the
# KMS port to the WG subnet. <T> is the per-agent auth token (kms_token_<N>).
ra_setup_kms() {
  local T="$1" addr port adir fp; addr="$(vault_kms_addr)"; port="$(vault_kms_port)"; adir="psai"
  vault_kms_start
  ra_ssh "mkdir -p ~/$adir/secrets; umask 077; cat > ~/$adir/secrets/kms.conf <<EOF
KMS_ADDR=${addr}
KMS_ID=${AGENT_INDEX}
KMS_TOKEN=${T}
EOF
chmod 600 ~/$adir/secrets/kms.conf" >/dev/null 2>&1 || true
  # Identity binding: read the agent's hardware fingerprint (same context the agent's
  # vault runs in) and store it in the keys store as agent_fp_<N>. Strong binding (DMI
  # product_uuid) needs the agent stack to run as root; otherwise it binds to machine-id.
  # home-relative path (no '~/'): a command containing '/' runs from the remote $HOME.
  fp="$(ra_ssh "$adir/bin/stack-vault fingerprint" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$fp" ]; then
    printf '%s' "$fp" | kms_store_put "agent_fp_${AGENT_INDEX}"
    printf '  %sHW fingerprint registered for %s%s\n' "$C_DIM" "$(agent_label)" "$C_RESET"
  else
    printf '  %sno HW fingerprint from %s — KMS unseal will not be hardware-bound%s\n' "$C_YELLOW" "$(agent_label)" "$C_RESET"
  fi
  detect_os
  if [ "$OS_TYPE" = "linux" ]; then local S=""; [ "$(id -u)" = 0 ] || S=sudo; $S ufw allow from "${REMOTE_WG_NET}.0/24" to any port "$port" proto tcp >/dev/null 2>&1 || true; fi
  printf '  %sKMS unseal configured for %s%s\n' "$C_DIM" "$(agent_label)" "$C_RESET"
}

# Rotate an agent's unseal key from the master. Generates a fresh K, tells the agent's
# running vault to RESEAL its blob under K (no secret values change), then adopts K in
# the master keys store (agent_unseal_<idx>) so the next KMS unseal uses it. Reachable
# over WireGuard; the agent vault must be unsealed (running) for the reseal. KMS-side
# rotation (rekey from a standalone KMS node) is planned — see TODO.md.
ra_rekey() {
  local idx=0 rest=""
  while [ $# -gt 0 ]; do
    case "$1" in --idx) idx="$2"; shift 2 ;; *) rest="$rest $1"; shift ;; esac
  done
  AGENT_INDEX="$idx"
  load_config 2>/dev/null || true
  # Default target = the agent's WG IP from the registry, unless --host was given.
  case " $rest " in
    *" --host "*) : ;;
    *) local wg; wg="$(printf '%s\n' $AGENT_SERVERS | awk -F: -v i="$idx" '$1==i{print $3}' | head -1)"
       [ -n "$wg" ] && RA_HOST="$wg" ;;
  esac
  ensure_sshpass || true
  # shellcheck disable=SC2086
  ra_parse_args $rest || return 1
  vault_enabled || { printf '%svault disabled — nothing to rotate%s\n' "$C_YELLOW" "$C_RESET" >&2; return 1; }
  vault_up || vault_start || { printf '%smaster vault not available%s\n' "$C_RED" "$C_RESET" >&2; return 1; }
  printf '%sRotating unseal key for %s%s\n' "$C_B" "$(agent_label "$idx")" "$C_RESET"
  local newk; newk="$(random_secret)"
  # 1) reseal the agent's blob under the new key (its vault adopts K in RAM too). The new
  #    key goes on STDIN (reseal reads it) — never in the command line, so it can't be read
  #    from the agent's `ps`/environ.
  if printf '%s' "$newk" | ra_ssh "psai/bin/stack-vault reseal --socket psai/vault.sock" >/dev/null 2>&1; then
    # 2) adopt K in the keys store (master vault or external KMS node) so the next
    #    KMS unseal of this agent uses it.
    printf '%s' "$newk" | kms_store_put "agent_unseal_${idx}"
    printf '  %srotated: agent blob re-sealed, agent_unseal_%s updated%s\n' "$C_GREEN" "$idx" "$C_RESET"
  else
    printf '  %sFAILED: agent reseal did not run (is its vault unsealed / reachable?) — master key unchanged%s\n' "$C_RED" "$C_RESET" >&2
    return 1
  fi
}

# State collection: pull a health/log snapshot from every registered node into the
# master's data/state/<idx>/ dir over WireGuard. Safe to schedule (cron). Complements
# the data pull — this is the "centralized state collection" the master is meant to do.
# Uses RA_KEY when set (ideal for cron); otherwise prompts once for a shared password.
ra_collect_state() {
  load_config 2>/dev/null || true
  [ -n "$AGENT_SERVERS" ] || { printf '%sno agents registered%s\n' "$C_DIM" "$C_RESET"; return 0; }
  if [ -z "${RA_KEY:-}" ] && [ -z "${RA_PASSFILE:-}" ]; then
    ensure_sshpass || true
    RA_PASSFILE="$(mktemp)"; chmod 600 "$RA_PASSFILE"
    printf '%s: ' "$(t ra_pass)"; stty -echo 2>/dev/null; IFS= read -r _p || true; stty echo 2>/dev/null; printf '\n'
    printf '%s' "$_p" > "$RA_PASSFILE"; unset _p
  fi
  RA_USER="${RA_USER:-root}"
  local base="$STACK_DIR/data/state" ts; base="${base}"; ts="$(date +%Y%m%d-%H%M%S)"; mkdir -p "$base"
  local e idx ip wg dom dir snap
  for e in $AGENT_SERVERS; do
    IFS=':' read -r idx ip wg dom <<EOF
$e
EOF
    [ -n "$wg" ] || continue
    AGENT_INDEX="$idx"                       # ra_wg_ssh targets agent_wg_ip from this
    dir="$base/$idx"; mkdir -p "$dir"; snap="$dir/$ts.txt"
    {
      printf '# agent_worker_%s  wg=%s  collected=%s\n\n## docker ps\n' "$idx" "$wg" "$ts"
      ra_wg_ssh 'docker ps --format "{{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null' 2>/dev/null
      printf '\n## host\n'
      ra_wg_ssh 'uptime; echo; df -h / | tail -1; free -m 2>/dev/null | sed -n 1,2p' 2>/dev/null
      printf '\n## recent logs (tail 40 / container)\n'
      ra_wg_ssh 'for c in $(docker ps --format "{{.Names}}" 2>/dev/null); do echo "=== $c ==="; docker logs --tail 40 "$c" 2>&1 | tail -40; done' 2>/dev/null
    } > "$snap" 2>/dev/null
    if [ -s "$snap" ]; then
      ln -sf "$ts.txt" "$dir/latest.txt" 2>/dev/null
      # Keep the 10 newest snapshots. Names are <ts>.txt so the glob expands oldest-first;
      # delete from the front until 10 remain (skip the latest.txt symlink).
      local keep=10 count=0 f
      for f in "$dir"/*.txt; do { [ -f "$f" ] && [ ! -L "$f" ]; } && count=$((count + 1)); done
      for f in "$dir"/*.txt; do
        [ "$count" -le "$keep" ] && break
        { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
        rm -f "$f"; count=$((count - 1))
      done
      printf '  %sagent_worker_%s%s → %s%s%s\n' "$C_B" "$idx" "$C_RESET" "$C_DIM" "$snap" "$C_RESET"
    else
      rm -f "$snap"; printf '  %sagent_worker_%s unreachable%s\n' "$C_YELLOW" "$idx" "$C_RESET"
    fi
  done
}

# Provision an external KMS node: a minimal host that runs only stack-vault + the KMS
# daemon and holds the keys store, separate from the master, so a compromised master
# does not expose every agent's key. It joins the fleet WireGuard net (default .254).
# Afterwards the master + agents fetch unseal from it (PSAI_KMS_HOST). FIRST CUT — the
# node's WireGuard peering and a two-host live e2e are the remaining steps (TODO.md).
ra_install_kms_node() {
  ensure_sshpass || true
  ra_parse_args "$@" || return 1
  vault_enabled || { printf '%sstrict profile (vault) required for a KMS node%s\n' "$C_YELLOW" "$C_RESET" >&2; return 1; }
  local kwg pass aarch tag pre src=""
  kwg="$(kms_wg_ip)"
  for d in "$SCRIPT_DIR/vault" "$SCRIPT_DIR/../vault"; do [ -f "$d/Cargo.toml" ] && { src="$d"; break; }; done
  [ -n "$src" ] || { printf '%sno vault source to ship%s\n' "$C_RED" "$C_RESET" >&2; return 1; }
  printf '%sProvisioning KMS node at %s (wg %s)%s\n' "$C_B" "$RA_HOST" "$kwg" "$C_RESET"
  setup_wg_kms_tunnel || { printf '%sWireGuard peering of the KMS node failed%s\n' "$C_RED" "$C_RESET" >&2; return 1; }
  aarch="$(ra_ssh 'uname -m' 2>/dev/null | tr -d '[:space:]')"
  case "$aarch" in x86_64|amd64) tag=x86_64 ;; aarch64|arm64) tag=aarch64 ;; *) tag="$aarch" ;; esac
  pre="$src/dist/stack-vault-linux-$tag"
  ra_ssh 'mkdir -p ~/psai/bin ~/psai/secrets ~/psai/data/logs' >/dev/null 2>&1 || true
  if [ -x "$pre" ]; then
    ra_scp "$pre" 'psai/bin/stack-vault'
  else
    ra_ssh 'mkdir -p ~/vault-src/src' >/dev/null 2>&1 || true
    ra_scp "$src/Cargo.toml" 'vault-src/Cargo.toml'; ra_scp "$src/src/main.rs" 'vault-src/src/main.rs'
    # Build from the shipped source using the distro's cargo (apt) rather than piping
    # rustup's installer into a shell. A prebuilt binary (above) is the preferred path.
    ra_ssh 'command -v cargo >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq cargo >/dev/null 2>&1; }; cd ~/vault-src && cargo build --release >/dev/null 2>&1 && cp target/release/stack-vault ~/psai/bin/stack-vault' >/dev/null 2>&1 || true
  fi
  ra_ssh 'chmod +x ~/psai/bin/stack-vault' >/dev/null 2>&1 || true
  pass="$(random_secret)"   # the KMS node's own unseal passphrase — the operator keeps it
  ra_ssh "PSAI_VAULT_PASS='$pass' nohup psai/bin/stack-vault serve --socket psai/vault.sock --blob psai/vault.enc >>psai/data/logs/vault.log 2>&1 & sleep 1; nohup psai/bin/stack-vault kms --listen ${kwg}:$(vault_kms_port) --socket psai/vault.sock >>psai/data/logs/vault.log 2>&1 &" >/dev/null 2>&1 || true
  KMS_HOST="$kwg"; KMS_SSH_USER="$RA_USER"; KMS_SSH_KEY="$RA_KEY"; save_config 2>/dev/null || true
  printf '  %sKMS node up.%s export %sPSAI_KMS_HOST=%s%s for agent installs.\n' "$C_GREEN" "$C_RESET" "$C_B" "$kwg" "$C_RESET"
  printf '  %skeep the KMS node passphrase safe: %s%s\n' "$C_YELLOW" "$pass" "$C_RESET"
  printf '  %sremaining: peer the node into the fleet WireGuard + two-host live test (TODO.md)%s\n' "$C_DIM" "$C_RESET"
}

ra_harden_vps2() {
  printf '%s...\n' "hardening agent"
  ra_ssh "cat > /etc/sysctl.d/99-psai.conf <<'SYS'
$(cis_sysctl_lines)
SYS
sysctl --system >/dev/null 2>&1 || true
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-psai.conf <<'SSHD'
$(cis_sshd_lines)
SSHD
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null 2>&1 || true" || true
  local web_rules=""
  [ "$AGENT_WEB" = "true" ] && web_rules="ufw allow 80/tcp >/dev/null 2>&1 || true; ufw allow 443/tcp >/dev/null 2>&1 || true"
  ra_ssh "ufw allow ${REMOTE_WG_PORT}/udp >/dev/null 2>&1 || true
$web_rules
ufw allow from ${REMOTE_WG_NET}.0/24 to any port 22 proto tcp >/dev/null 2>&1 || true
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1 || true
ufw default allow outgoing >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true" || true
}

ra_install_failback() {
  local mins="${SSH_FAILBACK_MIN:-10}"; case "$mins" in ''|*[!0-9]*) mins=10 ;; esac
  ra_ssh "cat > /etc/systemd/system/psai-ssh-open.service <<'U1'
[Unit]
Description=psai open public SSH at boot (failback)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/ufw allow 22/tcp
[Install]
WantedBy=multi-user.target
U1
cat > /etc/systemd/system/psai-ssh-lock.service <<'U2'
[Unit]
Description=psai re-lock public SSH
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'ufw delete allow 22/tcp || true'
U2
cat > /etc/systemd/system/psai-ssh-lock.timer <<U3
[Unit]
Description=psai lock public SSH ${mins} min after boot
[Timer]
OnBootSec=${mins}min
Unit=psai-ssh-lock.service
[Install]
WantedBy=timers.target
U3
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable psai-ssh-open.service >/dev/null 2>&1 || true
systemctl enable psai-ssh-lock.timer >/dev/null 2>&1 || true" || true
}

ra_lockdown_public_ssh() {
  if ra_wg_ssh 'echo ok' >/dev/null 2>&1; then
    ra_ssh 'ufw delete allow 22/tcp >/dev/null 2>&1 || true' || true
    printf '  %sSSH-over-WG verified — public SSH dropped%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '  %sSSH-over-WG not verified — leaving public SSH open%s\n' "$C_YELLOW" "$C_RESET"
  fi
}

ra_open_ssh() {
  local mins="${RA_OPEN_MIN:-$SSH_FAILBACK_MIN}"; case "$mins" in ''|*[!0-9]*) mins=10 ;; esac
  ra_wg_ssh 'echo ok' >/dev/null 2>&1 || { printf '%sno WG tunnel%s\n' "$C_RED" "$C_RESET"; return 1; }
  ra_wg_ssh "ufw allow 22/tcp >/dev/null 2>&1 || true
systemd-run --on-active=${mins}min --unit=psai-open-ssh-revert /bin/sh -c 'ufw delete allow 22/tcp || true' >/dev/null 2>&1 || true" || true
  printf '%spublic SSH open for %s min%s\n' "$C_GREEN" "$mins" "$C_RESET"
}

# Fleet: list registered agents + per-agent control over WG.
fleet_menu() {
  load_config || { echo "$(t no_env)"; return 1; }
  sub_header "$(t d_fleet)"
  [ -n "$AGENT_SERVERS" ] || { printf '  (no agents)\n'; return 0; }
  local e idx ip wg dom
  for e in $AGENT_SERVERS; do
    IFS=':' read -r idx ip wg dom <<EOF
$e
EOF
    printf '  %sagent_worker_%s%s  public %s  wg %s  %s\n' "$C_B" "$idx" "$C_RESET" "$ip" "$wg" "${dom:-WG-only}"
  done
  printf '\n  %s%s start|stop|status%s · %s%s agents --open-ssh N%s\n' \
    "$C_DIM" "$MGMT_NAME" "$C_RESET" "$C_DIM" "$MGMT_NAME" "$C_RESET"
}
