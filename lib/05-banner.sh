# ───────────────────────────── banners ─────────────────────────────
# Banner art comes from the release banner template. In TTY mode the dot above
# the final "i" blinks; non-TTY output stays plain for logs/tests.

_psai_banner_dot() {
  if is_tty; then
    printf '                                 %s%s░██%s%s%s\n' "$C_B" "$C_BLINK" "$C_RESET" "$C_B" "$C_MAGENTA"
  else
    printf '                                 ░██\n'
  fi
}

_psai_banner_art() {
  _psai_banner_dot
  cat <<EOF

░████████   ░███████   ░██████   ░██
░██    ░██ ░██              ░██  ░██
░██    ░██  ░███████   ░███████  ░██
░███   ░██        ░██ ░██   ░██  ░██
░██░█████   ░███████   ░█████░██ ░██
░██                version:    $STACK_VERSION
░██                release:   github
EOF
}

banner_install() {
  is_tty && printf '%s%s' "$C_B" "$C_MAGENTA"
  _psai_banner_art
  is_tty && printf '%s' "$C_RESET"
  printf '  %stitle%s %s%s%s   %schannel%s %s%s%s   %scommand%s %s%s%s\n' \
    "$C_DIM" "$C_RESET" "$C_B" "$PRODUCT_NAME" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$C_B" "$STACK_CHANNEL" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$C_B" "$MGMT_NAME" "$C_RESET"
  return 0
}

banner_stack() {
  is_tty && printf '%s%s' "$C_B" "$C_MAGENTA"
  _psai_banner_art
  is_tty && printf '%s' "$C_RESET"
  return 0
}

# Two context lines under the dashboard banner: version/channel/profile, then the
# stack name (user-chosen, default psai) · node · profile · primary domain.
render_context() {
  local prof="${DEPLOY_PROFILE:-local}" dom
  if [ "$prof" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ]; then dom="$PUBLIC_DOMAIN"; else dom="${PSAI_DOMAIN:-${DOMAIN_ZONE:-lan}}"; fi
  printf '  %sv%s · %s · %s%s\n' "$C_DIM" "$STACK_VERSION" "$STACK_CHANNEL" "$prof" "$C_RESET"
  printf '  %s%s%s%s · %s · %s · domain: %s%s\n' \
    "$C_B" "${STACK_NAME:-$DEFAULT_STACK_NAME}" "$C_RESET" \
    "$C_DIM" "${NODE_MODE:-single}" "$prof" "$dom" "$C_RESET"
  return 0
}
