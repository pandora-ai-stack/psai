# ───────────────────────────── stack-vault (secrets daemon) ─────────────────────────────
# When secrets encryption is on (SEC_SEAL), stack-vault becomes the secret store: all
# generated secrets live in the daemon's mlock'd RAM, served over a peer-cred-gated
# Unix socket. The only disk artifact is an AES-256-GCM blob (vault.enc).
#   Single node  → the local "stack vault" (manual passphrase).
#   Multi node   → the "KMS vault": the keys store + KMS server that unseals the agents,
#                  running on the master or on a separate KMS node (PSAI_KMS_HOST).
vault_enabled()  { [ "${SEC_SEAL:-false}" = "true" ]; }
# Display name for the vault by deployment role (single = stack vault, multi = KMS vault).
vault_role_label() {
  if [ "${NODE_MODE:-single}" = "multi" ]; then
    if [ -n "${KMS_HOST:-}" ]; then printf 'KMS vault · node %s' "$KMS_HOST"; else printf 'KMS vault'; fi
  else printf 'stack vault'; fi
}
vault_bin()      { printf '%s/bin/stack-vault' "$STACK_DIR"; }
vault_sock()     { printf '%s/vault.sock' "$STACK_DIR"; }
vault_blob()     { printf '%s/vault.enc' "$STACK_DIR"; }
vault_log()      { printf '%s/data/logs/vault.log' "$STACK_DIR"; }

vault_present()  { [ -x "$(vault_bin)" ]; }
vault_up()       { vault_present && "$(vault_bin)" ping --socket "$(vault_sock)" >/dev/null 2>&1; }
vault_sealed()   { ! vault_up; }
vault_serve_pids() {
  vault_present || return 0
  pgrep -f "$(vault_bin) serve --socket $(vault_sock) --blob $(vault_blob)" 2>/dev/null || true
}
vault_socket_pid() {
  command_exists lsof || return 0
  lsof -t "$(vault_sock)" 2>/dev/null | sed -n '1p'
}
vault_reap_duplicate_serves() {
  local pids="" pid keep="" count=0
  pids="$(vault_serve_pids)"
  for pid in $pids; do count=$((count + 1)); keep="$pid"; done
  [ "$count" -le 1 ] && return 0
  keep="$(vault_socket_pid)"
  if [ -z "$keep" ]; then
    for pid in $pids; do keep="$pid"; done
  fi
  for pid in $pids; do [ "$pid" = "$keep" ] || kill "$pid" 2>/dev/null || true; done
}
# Kill orphaned stack-vault serve daemons whose stack directory is gone — e.g. one left
# over after the stack was renamed or its dir removed (its --blob no longer matches the
# current vault path, so vault_reap_duplicate_serves never sees it). Safe by design: a
# live stack's blob directory still exists, so a running deployment is never touched.
vault_reap_orphan_serves() {
  command_exists pgrep || return 0
  local pid cmd blob dir
  for pid in $(pgrep -f 'stack-vault serve' 2>/dev/null); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || continue
    case "$cmd" in *--blob*) blob="${cmd#*--blob }"; blob="${blob%% *}" ;; *) continue ;; esac
    [ -n "$blob" ] || continue
    dir="$(dirname "$blob" 2>/dev/null)"
    [ -n "$dir" ] && [ ! -d "$dir" ] && kill "$pid" 2>/dev/null || true
  done
}

# Build stack-vault from source (vault/ next to the installer). Needs cargo; if it
# can't be built, the caller falls back to the file-based path and warns.
# Map uname -m to the release arch tag used in prebuilt filenames.
vault_arch_tag() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x86_64' ;;
    aarch64|arm64) printf 'aarch64' ;;
    *) uname -m ;;
  esac
}
# A release-shipped prebuilt for this OS/arch (vault/dist/stack-vault-<os>-<arch>), so a
# node without a Rust toolchain (e.g. a fresh agent) needs no cargo build.
vault_prebuilt() {
  detect_os 2>/dev/null || true
  local os tag d
  case "${OS_TYPE:-}" in linux) os=linux ;; macos) os=macos ;; *) os="$(uname -s | tr 'A-Z' 'a-z')" ;; esac
  tag="$(vault_arch_tag)"
  for d in "${PSAI_VAULT_DIST:-}" "$SCRIPT_DIR/vault/dist" "$SCRIPT_DIR/../vault/dist" "$SCRIPT_DIR/dist" "$STACK_DIR/vault-dist"; do
    [ -n "$d" ] && [ -x "$d/stack-vault-${os}-${tag}" ] && { printf '%s/stack-vault-%s-%s' "$d" "$os" "$tag"; return 0; }
  done
  return 1
}

build_vault() {
  vault_present && return 0
  # A prebuilt binary (from the release, verified via versions.json) wins if present.
  if [ -n "${PSAI_VAULT_BIN:-}" ] && [ -x "$PSAI_VAULT_BIN" ]; then
    mkdir -p "$STACK_DIR/bin"; cp "$PSAI_VAULT_BIN" "$(vault_bin)"; chmod +x "$(vault_bin)"; return 0
  fi
  local pre; if pre="$(vault_prebuilt)"; then
    mkdir -p "$STACK_DIR/bin"; cp "$pre" "$(vault_bin)"; chmod +x "$(vault_bin)"; return 0
  fi
  local src=""
  for d in "${PSAI_VAULT_SRC:-}" "$SCRIPT_DIR/vault" "$SCRIPT_DIR/../vault" "$STACK_DIR/vault-src"; do
    [ -n "$d" ] && [ -f "$d/Cargo.toml" ] && { src="$d"; break; }
  done
  [ -n "$src" ] || return 1
  ensure_path_brew
  if ! command_exists cargo; then
    detect_os
    case "$OS_TYPE" in
      macos) command_exists brew && brew install rust >/dev/null 2>&1 || true ;;
      linux) local S=""; [ "$(id -u)" = 0 ] || S=sudo; $S apt-get install -y -qq cargo >/dev/null 2>&1 || true ;;
    esac
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  command_exists cargo || return 1
  ( cd "$src" && cargo build --release >/dev/null 2>&1 ) || return 1
  mkdir -p "$STACK_DIR/bin"
  cp "$src/target/release/stack-vault" "$(vault_bin)" && chmod +x "$(vault_bin)"
}

# ── TPM auto-unseal (Linux, tpm2-tools) — optional, VAULT_TPM=true ──
# Seal the vault passphrase to THIS machine's TPM so the vault auto-unseals on this
# hardware only; the sealed blob is useless on any other machine (no passphrase on disk
# in plaintext). The owner-hierarchy primary is deterministic per-TPM, so the sealed
# objects re-load after reboot. macOS Secure Enclave needs a native helper (not bash) —
# tracked in TODO.md.
tpm_dir()            { printf '%s/secrets/tpm' "$STACK_DIR"; }
tpm_available()      { command_exists tpm2_createprimary && { [ -e /dev/tpmrm0 ] || [ -e /dev/tpm0 ]; }; }
tpm_sealed_present() { [ -f "$(tpm_dir)/seal.priv" ] && [ -f "$(tpm_dir)/seal.pub" ]; }
tpm_forget()         { rm -rf "$(tpm_dir)" 2>/dev/null || true; }   # disable TPM auto-unseal
tpm_seal_pass() {     # $1 = passphrase
  tpm_available || return 1
  local d; d="$(tpm_dir)"; mkdir -p "$d"; chmod 700 "$d"
  ( cd "$d" && tpm2_createprimary -Q -C o -c primary.ctx >/dev/null 2>&1 \
    && printf '%s' "$1" | tpm2_create -Q -C primary.ctx -i - -u seal.pub -r seal.priv >/dev/null 2>&1 ) \
    || { rm -f "$d"/seal.pub "$d"/seal.priv; return 1; }
  chmod 600 "$d"/seal.pub "$d"/seal.priv "$d"/primary.ctx 2>/dev/null || true
  printf '%sTPM: vault passphrase sealed to this machine%s\n' "$C_DIM" "$C_RESET" >&2
}
tpm_unseal_pass() {
  { tpm_available && tpm_sealed_present; } || return 1
  local d; d="$(tpm_dir)"
  ( cd "$d" && tpm2_createprimary -Q -C o -c primary.ctx >/dev/null 2>&1 \
    && tpm2_load -Q -C primary.ctx -u seal.pub -r seal.priv -c seal.ctx >/dev/null 2>&1 \
    && tpm2_unseal -Q -c seal.ctx 2>/dev/null )
}

# Unseal: start the daemon. The passphrase comes from the install (SEAL_PASS_PLAIN), the
# PSAI_VAULT_PASS env, the TPM (VAULT_TPM, auto-unseal to this machine), or a prompt.
# Nothing is stored on disk but the encrypted blob; without TPM a reboot loses the
# in-RAM key (sealed until re-entered).
vault_start() {
  vault_enabled || return 0
  vault_present || { build_vault || { printf '%svault unavailable — using file secrets%s\n' "$C_YELLOW" "$C_RESET" >&2; return 1; }; }
  vault_reap_orphan_serves
  vault_reap_duplicate_serves
  vault_up && return 0
  mkdir -p "$(dirname "$(vault_log)")"
  local sock blob; sock="$(vault_sock)"; blob="$(vault_blob)"
  local kmsconf="$STACK_DIR/secrets/kms.conf"
  if [ -f "$kmsconf" ]; then
    # KMS-unseal (agent): fetch the key from the master vault over WG. No passphrase
    # and no key on the agent's disk — the token in kms.conf only authenticates.
    local KMS_ADDR="" KMS_ID="" KMS_TOKEN=""
    # shellcheck disable=SC1090
    . "$kmsconf"
    nohup "$(vault_bin)" serve --socket "$sock" --blob "$blob" \
      --kms "$KMS_ADDR" --kms-id "$KMS_ID" --kms-token "$KMS_TOKEN" >>"$(vault_log)" 2>&1 &
  else
    local p; p="${SEAL_PASS_PLAIN:-${PSAI_VAULT_PASS:-}}"
    # TPM auto-unseal: recover the passphrase sealed to this machine's TPM.
    if [ -z "$p" ] && [ "${VAULT_TPM:-false}" = "true" ] && tpm_sealed_present; then
      p="$(tpm_unseal_pass 2>/dev/null)"
    fi
    if [ -z "$p" ]; then
      if [ "$NONINTERACTIVE" = "1" ]; then printf '%s%s%s\n' "$C_RED" "$(t vault_need_pass)" "$C_RESET" >&2; return 1; fi
      printf '%s: ' "$(t vault_pass)" >&2; stty -echo 2>/dev/null; IFS= read -r p; stty echo 2>/dev/null; printf '\n' >&2
    fi
    PSAI_VAULT_PASS="$p" nohup "$(vault_bin)" serve --socket "$sock" --blob "$blob" >>"$(vault_log)" 2>&1 &
  fi
  local i=0; while [ "$i" -lt 25 ]; do
    if vault_up; then
      vault_reap_duplicate_serves
      # First successful unseal with VAULT_TPM: seal the passphrase to the TPM for next time.
      if [ "${VAULT_TPM:-false}" = "true" ] && [ -n "${p:-}" ] && ! tpm_sealed_present; then
        tpm_seal_pass "$p" 2>/dev/null || true
      fi
      return 0
    fi
    sleep 0.2; i=$((i + 1))
  done
  printf '%svault failed to start (wrong passphrase / KMS unreachable? see %s)%s\n' "$C_YELLOW" "$(vault_log)" "$C_RESET" >&2
  return 1
}

# KMS: serve agent unseal keys to WireGuard peers (bound to a WG IP only).
vault_kms_port()    { printf '%s' "${PSAI_KMS_PORT:-51821}"; }
vault_kms_running() { pgrep -f 'stack-vault kms' >/dev/null 2>&1; }
# Address that callers (master/agents) fetch unseal from. An external KMS node
# (PSAI_KMS_HOST) takes precedence; otherwise the KMS is co-located on the master.
vault_kms_addr() {
  if [ -n "${KMS_HOST:-}" ]; then printf '%s:%s' "$KMS_HOST" "$(vault_kms_port)"
  elif type master_wg_ip >/dev/null 2>&1; then printf '%s:%s' "$(master_wg_ip)" "$(vault_kms_port)"
  fi
}
# Start the local KMS service. Skipped when the KMS lives on its own node
# (PSAI_KMS_HOST set) — that host runs the daemon and holds the keys store.
vault_kms_start() {
  vault_enabled || return 0
  [ -n "${KMS_HOST:-}" ] && return 0          # external KMS node owns this
  vault_present && vault_up || return 0
  vault_kms_running && return 0
  type master_wg_ip >/dev/null 2>&1 || return 0
  local wg; wg="$(master_wg_ip)"; [ -n "$wg" ] || return 0
  nohup "$(vault_bin)" kms --listen "${wg}:$(vault_kms_port)" --socket "$(vault_sock)" >>"$(vault_log)" 2>&1 &
  printf '%sstack-vault KMS on %s:%s%s\n' "$C_DIM" "$wg" "$(vault_kms_port)" "$C_RESET" >&2
}
vault_kms_stop() { pkill -f 'stack-vault kms' 2>/dev/null || true; }

# Keys-store access. With an external KMS node (KMS_HOST) the agent keys
# (agent_unseal_<id> / kms_token_<id> / agent_fp_<id>) live on that node's vault, reached
# over WireGuard+SSH; otherwise they live in the local master vault. This is what lets a
# compromised master not expose every agent's key.
kms_node_ssh() {
  # Pin the KMS node's host key on first contact (TOFU) via the persisted known_hosts,
  # instead of StrictHostKeyChecking=no which silently trusted any key on every connect.
  local h="${KMS_SSH_USER:-root}@${KMS_HOST}" kh; kh="$(ra_known_hosts)"
  if [ -n "${KMS_SSH_KEY:-}" ]; then ssh -i "$KMS_SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "$h" "$@"
  elif [ -n "${RA_PASSFILE:-}" ]; then sshpass -f "$RA_PASSFILE" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "$h" "$@"
  else ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "$h" "$@"; fi
}
kms_store_put() {   # $1=key, value on stdin
  if [ -n "${KMS_HOST:-}" ]; then kms_node_ssh "psai/bin/stack-vault put $1 --socket psai/vault.sock"
  else vault_put "$1"; fi
}
kms_store_get() {   # $1=key
  if [ -n "${KMS_HOST:-}" ]; then kms_node_ssh "psai/bin/stack-vault get $1 --socket psai/vault.sock" 2>/dev/null || true
  else vault_get "$1"; fi
}

# Seal: tell the daemon to persist + wipe memory + exit.
vault_seal() {
  vault_enabled || return 0
  vault_up || return 0
  "$(vault_bin)" seal --socket "$(vault_sock)" >/dev/null 2>&1 || true
}

# get exits 1 on a missing key — '|| true' keeps `set -e` from aborting the caller.
vault_get() { "$(vault_bin)" get "$1" --socket "$(vault_sock)" 2>/dev/null || true; }
vault_put() { "$(vault_bin)" put "$1" --socket "$(vault_sock)" >/dev/null 2>&1; }   # value on stdin

vault_status_label() {
  if ! vault_enabled; then printf '%s' "$(t seal_off)"
  elif vault_up;       then printf '%s' "$(t seal_unsealed)"
  else                      printf '%s' "$(t seal_sealed)"; fi
}
