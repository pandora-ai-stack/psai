# ───────────────────────────── screen / os ─────────────────────────────
clear_screen() { if is_tty; then clear 2>/dev/null || true; fi; return 0; }

detect_arch() {
  case "$(uname -m 2>/dev/null)" in
    arm64|aarch64) ARCH_TYPE="arm64" ;;
    x86_64|amd64)  ARCH_TYPE="x64" ;;
    i386|i686)     ARCH_TYPE="x86" ;;
    *)             ARCH_TYPE="unknown" ;;
  esac
}

detect_os() {
  case "$(uname -s)" in
    Darwin) OS_TYPE="macos" ;;
    Linux)  OS_TYPE="linux" ;;
    *)      OS_TYPE="unknown" ;;
  esac
  detect_arch
}

os_pretty() {
  case "$OS_TYPE" in
    macos) printf 'macOS %s (%s)' "$(sw_vers -productVersion 2>/dev/null)" "$(uname -m)";;
    linux)
      if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release; printf '%s (%s)' "${PRETTY_NAME:-Linux}" "$(uname -m)"
      else printf 'Linux (%s)' "$(uname -m)"; fi ;;
    *) printf '%s' "$(uname -srm)";;
  esac
}

host_ip() {
  local ip=""
  case "$OS_TYPE" in
    macos)
      ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
      [ -z "$ip" ] && ip="$(ipconfig getifaddr en1 2>/dev/null || true)" ;;
    linux)
      ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
      [ -z "$ip" ] && ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')" ;;
  esac
  [ -z "$ip" ] && ip="n/a"
  printf '%s' "$ip"
}

# ───────────────────────────── runtime metrics ─────────────────────────────
ncpu() { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1; }
sys_disk_pct() { df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}'; }
sys_ram_pct() {
  case "$OS_TYPE" in
    macos)
      local ps total f="" i="" sp=""
      ps=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
      total=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
      [ "${total:-0}" -gt 0 ] 2>/dev/null || return 0
      eval "$(vm_stat 2>/dev/null | awk -F: '
        /Pages free/        {gsub(/[ .]/,"",$2); print "f="$2}
        /Pages inactive/    {gsub(/[ .]/,"",$2); print "i="$2}
        /Pages speculative/ {gsub(/[ .]/,"",$2); print "sp="$2}')"
      local avail=$(( ( ${f:-0} + ${i:-0} + ${sp:-0} ) * ps ))
      printf '%d' $(( (total - avail) * 100 / total )) ;;
    linux) free 2>/dev/null | awk '/^Mem:/{ if($2>0) printf "%d", $3/$2*100; exit }' ;;
  esac
}
sys_cpu_pct() {
  local la nc; nc="$(ncpu)"
  la="$(uptime 2>/dev/null | sed -n 's/.*load average[s]*:[ ]*\([0-9.]*\).*/\1/p')"
  [ -n "$la" ] || return 0
  awk -v l="$la" -v n="$nc" 'BEGIN{ if(n<1)n=1; v=l/n*100; if(v>100)v=100; printf "%d", v }'
}
docker_server_version() { docker version --format '{{.Server.Version}}' 2>/dev/null; }
docker_vm_info() {
  local raw nc mem; raw="$(docker info --format '{{.NCPU}}|{{.MemTotal}}' 2>/dev/null)" || raw=""
  [ -n "$raw" ] || return 0
  nc="${raw%%|*}"; mem="${raw##*|}"
  awk -v c="$nc" -v m="$mem" 'BEGIN{ printf "%s vCPU / %.1f GB", c, m/1073741824 }'
}
pct_or_dash() { case "${1:-}" in ''|-) printf '—' ;; *) printf '%s%%' "$1" ;; esac; }
status_dot() { printf '%s●%s' "${1:-$C_GREEN}" "$C_RESET"; }

RT_HOST="" RT_IP="" RT_RAM="" RT_CPU="" RT_DISK="" RT_DVER="" RT_DVM=""
collect_runtime() {
  RT_HOST="$(hostname 2>/dev/null)"
  # shellcheck disable=SC2034
  RT_IP="$(host_ip)"
  RT_DISK="$(pct_or_dash "$(sys_disk_pct)")"
  RT_RAM="$(pct_or_dash "$(sys_ram_pct)")"
  RT_CPU="$(pct_or_dash "$(sys_cpu_pct)")"
  if command_exists docker && docker info >/dev/null 2>&1; then
    RT_DVER="$(docker_server_version || true)"; [ -n "$RT_DVER" ] || RT_DVER="—"
    RT_DVM="$(docker_vm_info || true)";         [ -n "$RT_DVM" ]  || RT_DVM="—"
  else RT_DVER="—"; RT_DVM="—"; fi
}

# Dashboard section header: a bold-cyan title with a dim horizontal rule beneath it, so the
# Host / Components / Network / Secrets blocks read as cleanly separated sections.
section_header() {
  # shellcheck disable=SC2046
  printf '\n  %s%s%s\n  %s%s%s\n' "$C_B$C_CYAN" "$1" "$C_RESET" \
    "$C_DIM" "$(printf '─%.0s' $(seq 1 50))" "$C_RESET"
}

render_runtime() {
  local hc="$C_GREEN" dc="$C_GREEN"
  [ "${UPDATE_AVAILABLE:-false}" = "true" ] && hc="$C_YELLOW"
  [ "$RT_DVER" = "—" ] && dc="$C_RED"
  section_header "$(t sec_runtime)"
  printf '    %s %s%-8s%s %s%-16s%s  %sRAM:%s %-5s %sCPU:%s %-5s %sDISK:%s %-5s\n' \
    "$(status_dot "$hc")" "$C_DIM" "HOST:" "$C_RESET" "$C_B" "$RT_HOST" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$RT_RAM" "$C_DIM" "$C_RESET" "$RT_CPU" "$C_DIM" "$C_RESET" "$RT_DISK"
  printf '    %s %s%-8s%s %s%-16s%s  %sVM:%s %s\n' \
    "$(status_dot "$dc")" "$C_DIM" "DOCKER:" "$C_RESET" "$C_B" "$RT_DVER" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$RT_DVM"
}

# ───────────────────────────── headers ─────────────────────────────
header_install() {
  clear_screen
  banner_install
  collect_runtime
  render_runtime
  printf '\n'
}

# Light header for sub-screens (breadcrumb only).
sub_header() {
  clear_screen
  printf '%s%s%s %s›%s %s%s%s\n\n' \
    "$C_B" "$PRODUCT_NAME" "$C_RESET" "$C_DIM" "$C_RESET" "$C_B$C_CYAN" "$1" "$C_RESET"
}

# ───────────────────────────── language ─────────────────────────────
load_lang() {
  if [ -n "$UI_LANG" ]; then return 0; fi
  if [ -f "$LANG_STORE" ]; then UI_LANG="$(tr -d '[:space:]' < "$LANG_STORE" 2>/dev/null)"; fi
  case "$UI_LANG" in ru|en) ;; *) UI_LANG="" ;; esac
}
save_lang() {
  mkdir -p "$(dirname "$LANG_STORE")" 2>/dev/null || true
  printf '%s\n' "$UI_LANG" > "$LANG_STORE" 2>/dev/null || true
}
choose_lang() {
  if [ "$NONINTERACTIVE" = "1" ]; then [ -z "$UI_LANG" ] && UI_LANG="en"; return 0; fi
  clear_screen; banner_install; printf '\n'
  printf '  %s\n\n' "$(t lang_pick)"
  printf '   %s[1]%s English\n' "$C_B" "$C_RESET"
  printf '   %s[2]%s Русский\n\n' "$C_B" "$C_RESET"
  local c=""; printf '  > '; read_user_line c; c="$(trim "$c")"
  case "$c" in 2|ru|RU|р|Р) UI_LANG="ru" ;; *) UI_LANG="en" ;; esac
  save_lang
}
saved_lang_from_stack() {
  local envf v
  for envf in "$SCRIPT_DIR/.stack.env" "$SCRIPT_DIR/../.stack.env" "${STACK_DIR:-/nonexistent}/.stack.env"; do
    [ -f "$envf" ] || continue
    v="$(sed -n 's/^UI_LANG_SAVED="\(.*\)"$/\1/p' "$envf" 2>/dev/null | head -1)"
    case "$v" in ru|en) printf '%s' "$v"; return 0 ;; esac
  done
  return 1
}
ensure_lang() {
  if [ "${LANG_FROM_ENV:-0}" != "1" ]; then
    local s; s="$(saved_lang_from_stack || true)"; [ -n "$s" ] && UI_LANG="$s"
  fi
  load_lang
  [ -z "$UI_LANG" ] && UI_LANG="$(saved_lang_from_stack || true)"
  if [ -z "$UI_LANG" ]; then choose_lang; fi
  case "$UI_LANG" in ru|en) ;; *) UI_LANG="en" ;; esac
}
