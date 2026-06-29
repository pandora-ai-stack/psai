# ───────────────────────────── tiny helpers ─────────────────────────────
line() { printf '%s%s%s\n' "$C_DIM" '──────────────────────────────────────────────────────────────' "$C_RESET"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Copy stdin to the OS clipboard. 0 on success, 1 if no tool (headless). Never fails the caller.
copy_to_clipboard() {
  if command_exists pbcopy; then pbcopy
  elif command_exists wl-copy; then wl-copy
  elif command_exists xclip; then xclip -selection clipboard
  elif command_exists xsel; then xsel --clipboard --input
  else cat >/dev/null; return 1
  fi
}

safe_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/_+/_/g'
}

trim() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

prompt_printf() { printf "$@" >&2; }

read_user_line() {
  local __out_var="$1" __line=""
  IFS= read -r __line || true
  printf -v "$__out_var" '%s' "$__line"
}

# Read a secret twice without echo until the two entries are non-empty AND match, then
# assign it to the named variable. Prints a clear note on empty/mismatch instead of silently
# re-prompting. Shared by the admin password and the vault passphrase so both are confirmed.
read_secret_confirmed() {
  local __var="$1" __label="$2" __p1 __p2
  while true; do
    printf '  %s: ' "$__label"; stty -echo 2>/dev/null; IFS= read -r __p1 || true; stty echo 2>/dev/null; printf '\n'
    if [ -z "$__p1" ]; then printf '  %s%s%s\n' "$C_YELLOW" "$(t pw_empty)" "$C_RESET"; continue; fi
    printf '  %s: ' "$(t pw_repeat)"; stty -echo 2>/dev/null; IFS= read -r __p2 || true; stty echo 2>/dev/null; printf '\n'
    if [ "$__p1" = "$__p2" ]; then printf -v "$__var" '%s' "$__p1"; break; fi
    printf '  %s%s%s\n' "$C_YELLOW" "$(t pw_mismatch)" "$C_RESET"
  done
}

pause() {
  is_interactive || return 0
  printf '\n%s ' "$(t press_enter)" >&2
  IFS= read -r _ || true
}

# ask "<prompt>" "<default>" -> echoes the answer (or default).
ask() {
  local prompt="$1" default="${2:-}" value=""
  if [ "$NONINTERACTIVE" = "1" ]; then printf '%s' "$default"; return 0; fi
  if [ -n "$default" ]; then prompt_printf '%s [%s]: ' "$prompt" "$default"; else prompt_printf '%s: ' "$prompt"; fi
  read_user_line value
  value="$(trim "$value")"
  if [ -z "$value" ]; then printf '%s' "$default"; else printf '%s' "$value"; fi
}

# prompt_set VAR "<prompt>" "<default>" -> assigns the answer to VAR.
prompt_set() {
  local __var="$1" __prompt="$2" __default="${3:-}" __value=""
  if [ "$NONINTERACTIVE" = "1" ]; then printf -v "$__var" '%s' "$__default"; return 0; fi
  if [ -n "$__default" ]; then prompt_printf '%s [%s]: ' "$__prompt" "$__default"; else prompt_printf '%s: ' "$__prompt"; fi
  read_user_line __value
  __value="$(trim "$__value")"
  [ -z "$__value" ] && __value="$__default"
  printf -v "$__var" '%s' "$__value"
}

# confirm "<prompt>" "<Y|N default>" -> 0 yes / 1 no.
confirm() {
  local prompt="$1" default="${2:-Y}" suffix='[Y/n]' answer=''
  case "$default" in n|N|no|NO|нет|НЕТ) suffix='[y/N]' ;; *) suffix='[Y/n]' ;; esac
  if [ "$NONINTERACTIVE" = "1" ]; then
    case "$default" in y|Y|yes|YES|да|ДА) return 0 ;; *) return 1 ;; esac
  fi
  prompt_printf '%s%s%s %s: ' "$C_YELLOW" "$prompt" "$C_RESET" "$suffix"
  read_user_line answer
  answer="$(trim "$answer")"; [ -z "$answer" ] && answer="$default"
  answer="$(printf '%s' "$answer" | tr -d '[][:space:]')"
  case "$answer" in y|Y|yes|YES|Yes|д|Д|да|ДА|Да) return 0 ;; *) return 1 ;; esac
}

# bool_label true|false -> localized on/off.
bool_label() { [ "${1:-false}" = "true" ] && printf '%s' "$(t on)" || printf '%s' "$(t off)"; }

# ───────────────────────────── compact one-line menus ─────────────────────────────
# Display width: ANSI stripped, UTF-8 aware (one Cyrillic/box char = 1 column).
vwidth() {
  local s b cont
  s="$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')"
  b=$(printf '%s' "$s" | LC_ALL=C wc -c); b="${b//[[:space:]]/}"
  cont=$(printf '%s' "$s" | LC_ALL=C tr -dc $'\200-\277' | wc -c); cont="${cont//[[:space:]]/}"
  printf '%d' $(( b - cont ))
}

# inline_opt key label -> "[key] label" with a cyan key. No newline.
inline_opt() { printf '%s[%s]%s %s' "$C_CYAN" "$1" "$C_RESET" "$2"; }

# menu_line "<title>" key1 label1 key2 label2 ...  -> one aligned row:
#   Title     [a] one        [b] two        [c] three
# The dim title is padded to a fixed column; each option is padded so options line
# up in columns across rows (the two-column / grid layout).
MENU_LABEL_W="${MENU_LABEL_W:-10}"
MENU_OPT_W="${MENU_OPT_W:-16}"
menu_line() {
  local title="$1"; shift
  local pad; pad=$(( MENU_LABEL_W - $(vwidth "$title") )); [ "$pad" -lt 1 ] && pad=1
  printf '  %s%s%s%*s' "$C_DIM" "$title" "$C_RESET" "$pad" ''
  local opt ow
  while [ $# -ge 2 ]; do
    opt="$(inline_opt "$1" "$2")"; ow=$(( MENU_OPT_W - $(vwidth "$opt") )); [ "$ow" -lt 1 ] && ow=1
    printf '%s%*s' "$opt" "$ow" ''
    shift 2
  done
  printf '\n'
}

# ───────────────────────────── step spinner ─────────────────────────────
SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
STEP_NUM=0
STEP_TOTAL=0

# run_step "<label>" cmd args... -> spinner while running, ✔/✖ at the end.
run_step() {
  local label="$1"; shift
  local prefix=""
  if [ "$STEP_TOTAL" -gt 0 ]; then
    STEP_NUM=$((STEP_NUM + 1))
    prefix="$(printf '%s[%d/%d]%s ' "$C_DIM" "$STEP_NUM" "$STEP_TOTAL" "$C_RESET")"
  fi
  if ! is_tty; then
    printf '%s%s …\n' "$prefix" "$label"
    "$@"; return $?
  fi
  local logf rc i frame pid
  logf="$(mktemp)"
  ("$@") >"$logf" 2>&1 &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    frame="${SPIN_FRAMES:$((i % ${#SPIN_FRAMES})):1}"
    printf '\r%s%s%s%s %s ' "$prefix" "$C_CYAN" "$frame" "$C_RESET" "$label" >&2
    i=$((i + 1)); sleep 0.1
  done
  rc=0; wait "$pid" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '\r%s%s✔%s %s\033[K\n' "$prefix" "$C_GREEN" "$C_RESET" "$label" >&2
  else
    printf '\r%s%s✖%s %s\033[K\n' "$prefix" "$C_RED" "$C_RESET" "$label" >&2
    printf '%s\n' "${C_DIM}--- output ---${C_RESET}" >&2
    tail -n 40 "$logf" >&2
  fi
  rm -f "$logf"
  return $rc
}
