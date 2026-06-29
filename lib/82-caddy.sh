# ───────────────────────────── caddy / TLS ─────────────────────────────
# TLS source:
#   local profile            -> local CA (we issue + the host trusts root.crt)
#   public + domain + le     -> ACME (Let's Encrypt)
#   public + domain + own    -> bring-your-own cert files
#   public + no domain (self)-> self-signed for the host IP (reach the stack by IP)
caddy_use_acme()     { [ "$DEPLOY_PROFILE" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ] && [ "${TLS_MODE:-le}" = "le" ]; }
caddy_use_own_cert() { [ "$DEPLOY_PROFILE" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ] && [ "${TLS_MODE:-le}" = "own" ]; }
caddy_use_self()     { [ "$DEPLOY_PROFILE" = "public" ] && [ -z "${PUBLIC_DOMAIN:-}" ]; }

# The primary backend behind the main vhost: Open WebUI, or OpenHands if WebUI is off.
main_backend() {
  if [ "$ENABLE_OPENWEBUI" = "true" ]; then printf 'openwebui:8080'
  elif [ "$ENABLE_AGENTS" = "true" ]; then printf 'openhands:3000'
  else printf 'openwebui:8080'; fi
}
# The host the main vhost answers on.
main_host() {
  if caddy_use_self; then host_ip; else printf '%s' "$PSAI_DOMAIN"; fi
}

generate_local_ca_and_cert() {
  no_domain && return 0   # localhost ports over http — no certs needed
  caddy_use_acme && return 0
  caddy_use_own_cert && { install_own_cert; return 0; }
  local pki days leaf_days san i domains domain
  pki="$STACK_DIR/secrets/certificates"; mkdir -p "$pki"
  days=$(( ${CERT_YEARS:-3} * 365 )); [ "$days" -lt 365 ] && days=365
  leaf_days="$days"; [ "$leaf_days" -gt 397 ] && leaf_days=397   # Apple caps server certs at 398d
  domains="$PSAI_DOMAIN"
  [ "$ENABLE_AGENTS" = "true" ] && domains="$domains $AGENTS_DOMAIN"
  [ "$ENABLE_GIT" = "true" ]    && domains="$domains $GIT_DOMAIN $GIT_SSH_HOST"
  [ "$ENABLE_QDRANT" = "true" ] && domains="$domains $QDRANT_DOMAIN"

  if [ ! -f "$pki/root.key" ] || [ ! -f "$pki/root.crt" ]; then
    openssl genrsa -out "$pki/root.key" 4096 >/dev/null 2>&1
    openssl req -x509 -new -nodes -key "$pki/root.key" -sha256 -days "$days" \
      -subj "/CN=${STACK_NAME} Local Root CA/O=psai" -out "$pki/root.crt" >/dev/null 2>&1
    chmod 600 "$pki/root.key"
  fi
  san="$pki/san.cnf"
  {
    printf '[req]\ndistinguished_name=req\n[v3_req]\n'
    printf 'keyUsage = digitalSignature, keyEncipherment\nextendedKeyUsage = serverAuth\nsubjectAltName = @alt_names\n[alt_names]\n'
    i=1
    # shellcheck disable=SC2086
    for domain in $domains localhost; do printf 'DNS.%s = %s\n' "$i" "$domain"; i=$((i + 1)); done
    printf 'IP.1 = 127.0.0.1\nIP.2 = ::1\n'
    caddy_use_self && printf 'IP.3 = %s\n' "$(host_ip)"
  } > "$san"
  openssl genrsa -out "$pki/local.key" 2048 >/dev/null 2>&1
  openssl req -new -key "$pki/local.key" -subj "/CN=$(main_host)" -out "$pki/local.csr" >/dev/null 2>&1
  openssl x509 -req -in "$pki/local.csr" -CA "$pki/root.crt" -CAkey "$pki/root.key" -CAcreateserial \
    -out "$pki/local.crt" -days "$leaf_days" -sha256 -extfile "$san" -extensions v3_req >/dev/null 2>&1
  chmod 600 "$pki/local.key"
}

install_own_cert() {
  local pki="$STACK_DIR/secrets/certificates"; mkdir -p "$pki"
  [ -f "${OWN_CERT_PATH/#\~/$HOME}" ] && cp "${OWN_CERT_PATH/#\~/$HOME}" "$pki/own.crt"
  [ -f "${OWN_KEY_PATH/#\~/$HOME}" ]  && cp "${OWN_KEY_PATH/#\~/$HOME}"  "$pki/own.key"
  chmod 600 "$pki/own.key" 2>/dev/null || true
}

# Dual access: append plain loopback-port vhosts (localhost-only, no TLS/auth) so the stack is
# reachable on http://localhost:PORT in addition to the .lan HTTPS domains. Local profile only.
write_caddy_dual_loopback() {
  dual_access || return 0
  local f="$STACK_DIR/compose/Caddyfile" mb; mb="$(main_backend)"
  {
    printf '\n(loop) {\n    encode zstd gzip\n    header -Server\n}\n'
    [ "$ENABLE_OPENWEBUI" = "true" ] && printf '\n:%s {\n    import loop\n    reverse_proxy %s\n}\n' "$PORT_PSAI" "$mb"
    [ "$ENABLE_OPENWEBUI" != "true" ] && [ "$ENABLE_AGENTS" = "true" ] && printf '\n:%s {\n    import loop\n    reverse_proxy openhands:3000\n}\n' "$PORT_PSAI"
    [ "$ENABLE_OPENWEBUI" = "true" ] && [ "$ENABLE_AGENTS" = "true" ] && printf '\n:%s {\n    import loop\n    reverse_proxy openhands:3000\n}\n' "$PORT_AGENTS"
    [ "$ENABLE_GIT" = "true" ]    && printf '\n:%s {\n    import loop\n    reverse_proxy forgejo:3000\n}\n' "$PORT_GIT"
    [ "$ENABLE_QDRANT" = "true" ] && printf '\n:%s {\n    import loop\n    reverse_proxy qdrant:6333\n}\n' "$PORT_QDRANT"
  } >> "$f"
}

write_caddyfile() {
  local f="$STACK_DIR/compose/Caddyfile"
  local webui_hash="" agents_hash="" qdrant_hash=""
  [ "$ENABLE_AGENTS" = "true" ]   && agents_hash="$(hash_password "$(secret_get agents_basic_auth)")"
  [ "$ENABLE_QDRANT" = "true" ]   && qdrant_hash="$(hash_password "$(secret_get qdrant_basic_auth)")"
  # Open WebUI has its own login; add a Caddy gate only on public deployments.
  [ "$ENABLE_OPENWEBUI" = "true" ] && [ "$DEPLOY_PROFILE" = "public" ] && webui_hash="$(hash_password "$(secret_get webui_basic_auth)")"

  # No-domain local mode: each service on its own loopback HTTP port, no TLS/host match.
  if no_domain; then
    {
      printf '{\n    admin off\n}\n\n'
      printf '(common_http) {\n    encode zstd gzip\n    header {\n'
      printf '        X-Content-Type-Options "nosniff"\n        X-Frame-Options "SAMEORIGIN"\n        -Server\n    }\n}\n\n'
      if [ "$ENABLE_OPENWEBUI" = "true" ]; then
        printf ':%s {\n    import common_http\n    reverse_proxy %s\n}\n\n' "$PORT_PSAI" "$(main_backend)"
      elif [ "$ENABLE_AGENTS" = "true" ]; then
        printf ':%s {\n    import common_http\n    basic_auth {\n        %s %s\n    }\n    reverse_proxy openhands:3000\n}\n\n' "$PORT_PSAI" "$ADMIN_USER" "$(hash_password "$(secret_get agents_basic_auth)")"
      fi
      if [ "$ENABLE_OPENWEBUI" = "true" ] && [ "$ENABLE_AGENTS" = "true" ]; then
        printf ':%s {\n    import common_http\n    basic_auth {\n        %s %s\n    }\n    reverse_proxy openhands:3000\n}\n\n' "$PORT_AGENTS" "$ADMIN_USER" "$(hash_password "$(secret_get agents_basic_auth)")"
      fi
      [ "$ENABLE_GIT" = "true" ]    && printf ':%s {\n    import common_http\n    reverse_proxy forgejo:3000\n}\n\n' "$PORT_GIT"
      [ "$ENABLE_QDRANT" = "true" ] && printf ':%s {\n    import common_http\n    basic_auth {\n        %s %s\n    }\n    reverse_proxy qdrant:6333\n}\n\n' "$PORT_QDRANT" "$ADMIN_USER" "$(hash_password "$(secret_get qdrant_basic_auth)")"
    } > "$f"
    return 0
  fi

  # global options
  {
    printf '{\n    admin off\n'
    caddy_use_acme && [ -n "${ACME_EMAIL:-}" ] && printf '    email %s\n' "$ACME_EMAIL"
    printf '}\n\n'
  } > "$f"

  # shared snippet
  {
    printf '(common) {\n'
    if caddy_use_own_cert; then printf '    tls /certs/own.crt /certs/own.key\n'
    elif ! caddy_use_acme;  then printf '    tls /certs/local.crt /certs/local.key\n'; fi
    printf '    encode zstd gzip\n'
    printf '    header {\n'
    printf '        Strict-Transport-Security "max-age=31536000"\n'
    printf '        X-Content-Type-Options "nosniff"\n'
    printf '        X-Frame-Options "SAMEORIGIN"\n'
    printf '        Referrer-Policy "strict-origin-when-cross-origin"\n        -Server\n    }\n'
    if [ "$DEPLOY_PROFILE" = "public" ]; then
      printf '    log {\n        output file /data/logs/caddy/access.log {\n            roll_size 10MiB\n            roll_keep 5\n        }\n        format json\n    }\n'
    fi
    printf '}\n\n'
  } >> "$f"

  local mb auth=""
  mb="$(main_backend)"
  # OpenHands as the main backend (no WebUI) gets basic_auth; WebUI gets it only on public.
  if [ "$ENABLE_OPENWEBUI" != "true" ] && [ "$ENABLE_AGENTS" = "true" ]; then
    auth="    basic_auth {
        $ADMIN_USER $agents_hash
    }
"
  elif [ -n "$webui_hash" ]; then
    auth="    basic_auth {
        $ADMIN_USER $webui_hash
    }
"
  fi

  # localhost vhost only with the local CA (local profile).
  if [ "$DEPLOY_PROFILE" != "public" ]; then
    cat >> "$f" <<EOF
localhost, 127.0.0.1 {
    import common
$auth    reverse_proxy $mb
}

EOF
  fi

  cat >> "$f" <<EOF
$(main_host) {
    import common
$auth    reverse_proxy $mb
}
EOF

  # OpenHands on its own vhost (when WebUI is the main backend).
  if [ "$ENABLE_AGENTS" = "true" ] && [ "$ENABLE_OPENWEBUI" = "true" ] && ! caddy_use_self; then
    cat >> "$f" <<EOF

$AGENTS_DOMAIN {
    import common
    basic_auth {
        $ADMIN_USER $agents_hash
    }
    reverse_proxy openhands:3000
}
EOF
  fi

  if [ "$ENABLE_GIT" = "true" ] && ! caddy_use_self; then
    cat >> "$f" <<EOF

$GIT_DOMAIN {
    import common
    reverse_proxy forgejo:3000
}
EOF
  fi

  if [ "$ENABLE_QDRANT" = "true" ] && ! caddy_use_self; then
    cat >> "$f" <<EOF

$QDRANT_DOMAIN {
    import common
    basic_auth {
        $ADMIN_USER $qdrant_hash
    }
    reverse_proxy qdrant:6333
}
EOF
  fi
  write_caddy_dual_loopback
}
