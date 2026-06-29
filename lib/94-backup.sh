# ───────────────────────────── backup / restore ─────────────────────────────
# Encrypted 7z archive of .stack.env + secrets + data. Password = the seal pass
# (auto/manual) when sealing is on, else a prompt.
backup_pass() {
  if seal_enabled; then seal_pass; else
    local p; printf 'Backup password: ' >&2; stty -echo 2>/dev/null; IFS= read -r p; stty echo 2>/dev/null; printf '\n' >&2; printf '%s' "$p"
  fi
}

backup_stack() {
  load_config || { echo "$(t no_env)"; return 1; }
  ensure_path_brew; sevenzip_detect
  [ -n "$SEVENZIP_BIN" ] || { echo '7z not found.'; return 1; }
  local dir="${1:-$STACK_DIR/backups}"; mkdir -p "$dir"
  local out; out="$dir/${SAFE_STACK_NAME}_$(date +%Y%m%d_%H%M%S).7z"
  local pass; pass="$(backup_pass)"
  ( cd "$STACK_DIR" && "$SEVENZIP_BIN" a -t7z -mhe=on -p"$pass" "$out" \
      .stack.env secrets data compose >/dev/null 2>&1 ) || { echo 'backup failed'; return 1; }
  ( cd "$dir" && shasum -a 256 "$(basename "$out")" > "$out.sha256" 2>/dev/null ) || true
  printf '%s%s%s %s\n' "$C_GREEN" "$(t done_word)" "$C_RESET" "$out"
}

restore_stack() {
  ensure_path_brew; sevenzip_detect
  [ -n "$SEVENZIP_BIN" ] || { echo '7z not found.'; return 1; }
  local arc="${1:-}" dst="${2:-}"
  [ -n "$arc" ] || arc="$(ask "$(t q_backup_path)" '')"
  [ -f "${arc/#\~/$HOME}" ] || { echo "Archive not found."; return 1; }
  arc="${arc/#\~/$HOME}"
  [ -n "$dst" ] || dst="$(ask "$(t q_restore_into)" "$(default_stack_dir_for "$DEFAULT_STACK_NAME")")"
  dst="${dst/#\~/$HOME}"; mkdir -p "$dst"
  local pass; printf 'Backup password: ' >&2; stty -echo 2>/dev/null; IFS= read -r pass; stty echo 2>/dev/null; printf '\n' >&2
  "$SEVENZIP_BIN" x -p"$pass" -o"$dst" "$arc" -y >/dev/null 2>&1 || { echo 'restore failed (wrong password?)'; return 1; }
  STACK_DIR="$dst"; load_config || true
  printf '%s%s%s %s\n' "$C_GREEN" "$(t done_word)" "$C_RESET" "$dst"
  printf '  %s%s start%s\n' "$C_DIM" "$MGMT_NAME" "$C_RESET"
}
