# ───────────────────────────── seal / unseal ─────────────────────────────
# At-rest encryption for secrets/. The encrypted blob (secrets.enc) is the source
# of truth, refreshed after every secret-changing op. When sealed, the plaintext
# secrets/ is wiped — the stack cannot run until unsealed.
#   auto   : passphrase in a host keyfile -> start auto-unseals.
#   manual : passphrase prompted on start; never stored. (strict profile)
# strict + manual + Linux + privilege -> RAM-unseal (plaintext lives in tmpfs only;
# a reboot wipes it). AES-256-CBC + PBKDF2 600k (openssl), no extra dependency.

seal_enabled() { [ "${SEAL_ENABLED:-false}" = "true" ]; }
seal_blob()    { printf '%s/secrets.enc' "$STACK_DIR"; }
seal_keyfile() { printf '%s/.config/psai/%s.sealkey' "$HOME" "$SAFE_STACK_NAME"; }
is_sealed()    { [ -f "$(seal_blob)" ] && [ ! -f "$STACK_DIR/secrets/passwords.txt" ]; }

seal_pass_auto() {
  local kf; kf="$(seal_keyfile)"; mkdir -p "$(dirname "$kf")"
  [ -s "$kf" ] || ( umask 077; openssl rand -base64 48 | tr -d '\n' > "$kf" )
  chmod 600 "$kf" 2>/dev/null || true
  cat "$kf"
}
seal_pass_prompt() {
  local p; printf '%s: ' "$(t d_seal)" >&2
  stty -echo 2>/dev/null; IFS= read -r p; stty echo 2>/dev/null; printf '\n' >&2
  printf '%s' "$p"
}
seal_pass() {
  if [ "${SEAL_MODE:-auto}" = "manual" ]; then
    [ -n "${SEAL_PASS_PLAIN:-}" ] && { printf '%s' "$SEAL_PASS_PLAIN"; return; }
    seal_pass_prompt
  else
    seal_pass_auto
  fi
}

seal_blob_write() {
  local pp="$1" tmp; tmp="$(seal_blob).tmp"
  [ -f "$STACK_DIR/secrets/passwords.txt" ] || return 0
  if tar -czf - -C "$STACK_DIR" secrets 2>/dev/null \
       | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "pass:$pp" -out "$tmp" 2>/dev/null; then
    mv "$tmp" "$(seal_blob)"; chmod 600 "$(seal_blob)" 2>/dev/null || true; return 0
  fi
  rm -f "$tmp"; return 1
}

# NOTE: the old tmpfs RAM-unseal is gone — stack-vault (lib/77-vault.sh) now keeps the
# plaintext in a daemon's mlock'd RAM for the strict/manual path. This openssl-blob
# seal remains only as the fallback when the vault can't be built.

seal_wipe() {
  vault_present && return 0
  [ -f "$(seal_blob)" ] || return 1
  find "$STACK_DIR/secrets" -type f 2>/dev/null | while IFS= read -r ff; do
    rm -P "$ff" 2>/dev/null || shred -u "$ff" 2>/dev/null || rm -f "$ff" 2>/dev/null || true
  done
  rm -rf "$STACK_DIR/secrets" 2>/dev/null || true
}

seal_decrypt() {
  local pp="$1"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "pass:$pp" -in "$(seal_blob)" 2>/dev/null \
    | tar -xzf - -C "$STACK_DIR" 2>/dev/null
  [ -f "$STACK_DIR/secrets/passwords.txt" ]
}

reseal_blob() {
  vault_present && return 0
  seal_enabled || return 0
  is_sealed && return 0
  seal_blob_write "$(seal_pass)" || { printf 'seal: blob refresh failed\n' >&2; return 1; }
}

ensure_unsealed() {
  vault_present && return 0
  seal_enabled || return 0
  is_sealed || return 0
  local pp; pp="$(seal_pass)"
  if seal_decrypt "$pp"; then printf '%s\n' "$(t seal_unsealed)" >&2; return 0; fi
  printf '%s%s%s\n' "$C_RED" "seal: unseal failed" "$C_RESET" >&2; return 1
}

seal_now() {
  load_config || { echo "$(t no_env)"; return 1; }
  if vault_enabled; then vault_seal; printf '%s%s%s\n' "$C_GREEN" "$(t seal_sealed)" "$C_RESET"; return 0; fi
  seal_enabled || { echo "$(t disabled)"; return 0; }
  is_sealed && { echo "$(t seal_sealed)"; return 0; }
  reseal_blob || return 1
  ensure_path_brew; compose down >/dev/null 2>&1 || true
  seal_wipe
  printf '%s%s%s\n' "$C_GREEN" "$(t seal_sealed)" "$C_RESET"
}
unseal_now() {
  load_config || { echo "$(t no_env)"; return 1; }
  if vault_enabled; then vault_start && printf '%s%s%s\n' "$C_GREEN" "$(t seal_unsealed)" "$C_RESET"; return 0; fi
  seal_enabled || { echo "$(t disabled)"; return 0; }
  is_sealed || { echo "$(t seal_unsealed)"; return 0; }
  ensure_unsealed && printf '%s%s%s\n' "$C_GREEN" "$(t seal_unsealed)" "$C_RESET"
}

seal_status_label() {
  if ! seal_enabled; then printf '%s' "$(t seal_off)"
  elif is_sealed;     then printf '%s' "$(t seal_sealed)"
  else                     printf '%s' "$(t seal_unsealed)"; fi
}
