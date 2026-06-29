# ───────────────────────────── egress proxies ─────────────────────────────
# Two independent HTTP-proxy gateways, both default 'none' (DIRECT):
#   proxy-stack : the apps' LLM API egress (cloud + local) + component pulls.
#                 Internal-only — apps reach it by name (proxy-stack:<port>).
#   proxy-web   : the web worker — search + the OpenHands sandbox's browsing.
#                 Published on host loopback so the sandbox (separate net) can reach it.
# Modes: tor | vless use an HTTP listener on 8118; wireguard/adguardvpn/tailscale
# tunnel via a tinyproxy sidecar on 8888 that shares the tunnel container's netns.

egress_stack_enabled() { [ -n "${EGRESS_STACK:-}" ] && [ "$EGRESS_STACK" != "none" ]; }
egress_web_enabled()   { [ -n "${EGRESS_WEB:-}" ]   && [ "$EGRESS_WEB" != "none" ]; }
stack_via_proxy() { [ "${STACK_VIA_PROXY:-true}" = "true" ]; }
web_via_proxy()   { [ "${WEB_VIA_PROXY:-true}"   = "true" ]; }

eg_mode_port() { case "$1" in tor|vless) printf '8118' ;; *) printf '8888' ;; esac; }

# Host bind address for proxy-web's published port. The OpenHands sandbox is a SEPARATE
# container that reaches the proxy via host.docker.internal. On Docker Desktop (macOS/
# Windows) that maps to the host and 127.0.0.1 is reachable; on native Linux it resolves to
# the docker bridge gateway, so a 127.0.0.1-only publish is unreachable from the sandbox —
# browsing then fails CLOSED (the proxy env points at a dead address). Bind to the bridge
# gateway on Linux: reachable by containers via host-gateway, NOT exposed off-host.
eg_web_bind() {
  detect_os 2>/dev/null || true
  if [ "${OS_TYPE:-}" = "linux" ]; then
    local gw; gw="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | head -1)"
    [ -n "$gw" ] && { printf '%s' "$gw"; return 0; }
  fi
  printf '127.0.0.1'
}

compute_egress_endpoints() {
  EGRESS_STACK_HTTP=""; EGRESS_WEB_HTTP=""; EG_SANDBOX_HTTP=""
  egress_stack_enabled && EGRESS_STACK_HTTP="http://proxy-stack:$(eg_mode_port "$EGRESS_STACK")"
  if egress_web_enabled; then
    EGRESS_WEB_HTTP="http://proxy-web:$(eg_mode_port "$EGRESS_WEB")"
    EG_SANDBOX_HTTP="http://host.docker.internal:${EG_HOST_WEB_PORT}"
  fi
}

# NO_PROXY for the apps. Local model endpoint (host.docker.internal) is excluded
# UNLESS PSAI_ROUTE_LOCAL_LLM=true (then local model calls also flow via proxy-stack).
egress_no_proxy() {
  local np="localhost,127.0.0.1,::1,openwebui,openhands,searxng,qdrant,mcp,mcp-gateway,memory,embed,ollama,litellm,langfuse,langfuse-db,ingest-docling,ingest-tika,falkordb,forgejo,caddy,proxy-stack,proxy-web,.${DOMAIN_BASE}"
  [ "${ROUTE_LOCAL_LLM:-false}" = "true" ] || np="$np,host.docker.internal"
  printf '%s' "$np"
}

# Proxy env lines for the APPS (openwebui/openhands) — their LLM API egress via proxy-stack.
stack_env_lines() {
  egress_stack_enabled || return 0
  stack_via_proxy || return 0
  compute_egress_endpoints
  local np; np="$(egress_no_proxy)"
  cat <<EOF
      - HTTP_PROXY=$EGRESS_STACK_HTTP
      - HTTPS_PROXY=$EGRESS_STACK_HTTP
      - http_proxy=$EGRESS_STACK_HTTP
      - https_proxy=$EGRESS_STACK_HTTP
      - NO_PROXY=$np
      - no_proxy=$np
EOF
}

# Sandbox Dockerfile proxy ENV — the OpenHands sandbox browses via proxy-web.
sandbox_proxy_env_lines() {
  egress_web_enabled || return 0
  web_via_proxy || return 0
  compute_egress_endpoints
  cat <<EOF
ENV HTTP_PROXY=$EG_SANDBOX_HTTP HTTPS_PROXY=$EG_SANDBOX_HTTP http_proxy=$EG_SANDBOX_HTTP https_proxy=$EG_SANDBOX_HTTP
ENV NO_PROXY=localhost,127.0.0.1,host.docker.internal no_proxy=localhost,127.0.0.1,host.docker.internal
EOF
}

# SearXNG settings.yml (we own it now): json format for Open WebUI + optional
# search-engine egress via proxy-web. Written directly into data/searxng.
write_searxng_settings() {
  [ "$ENABLE_SEARCH" = "true" ] || return 0
  mkdir -p "$STACK_DIR/data/searxng"
  compute_egress_endpoints
  local proxied="false" sx
  egress_web_enabled && web_via_proxy && proxied="true"
  # Real session key, taken from the secret store (stack-vault when sealed, else the
  # 0600 passwords.txt). The base searxng/searxng image only randomizes secret_key when
  # it CREATES settings.yml from its template (if [ ! -f ]) and never reads SEARXNG_SECRET
  # — so a pre-written file left as "ultrasecretkey" would ship a world-known key. We
  # inject the generated secret directly; the file itself is 0600.
  sx="$(secret_get searxng_secret searxng_secret_gen)"
  ( umask 077; {
    printf 'use_default_settings: true\n'
    printf 'server:\n  secret_key: "%s"\n  limiter: false\n  image_proxy: true\n' "$sx"
    printf 'search:\n  formats:\n    - html\n    - json\n'
    if [ "$proxied" = "true" ]; then
      printf 'outgoing:\n  request_timeout: 15.0\n  proxies:\n    all://:\n      - %s\n' "$EGRESS_WEB_HTTP"
    fi
  } > "$STACK_DIR/data/searxng/settings.yml" )
  chmod 600 "$STACK_DIR/data/searxng/settings.yml" 2>/dev/null || true
}

# ── provider config ─────────────────────────────────────────────────────────
vless_q() { printf '%s' "$1" | tr '&' '\n' | sed -n "s/^$2=//p" | head -1; }

write_xray_config() {
  local uri="$1" dir="$2" rest uuid hostport host port query
  rest="${uri#vless://}"; rest="${rest%%#*}"
  query="${rest#*\?}"; [ "$query" = "$rest" ] && query=""
  rest="${rest%%\?*}"
  uuid="${rest%@*}"; hostport="${rest#*@}"; host="${hostport%%:*}"; port="${hostport#*:}"
  local typ sec sni pbk sid flow fp
  typ="$(vless_q "$query" type)"; sec="$(vless_q "$query" security)"; sni="$(vless_q "$query" sni)"
  pbk="$(vless_q "$query" pbk)"; sid="$(vless_q "$query" sid)"; flow="$(vless_q "$query" flow)"; fp="$(vless_q "$query" fp)"
  [ -n "$typ" ] || typ="tcp"; [ -n "$sec" ] || sec="none"; [ -n "$fp" ] || fp="chrome"
  local reality=""
  [ "$sec" = "reality" ] && reality="\"realitySettings\": { \"serverName\": \"$sni\", \"fingerprint\": \"$fp\", \"publicKey\": \"$pbk\", \"shortId\": \"$sid\" },"
  mkdir -p "$dir"
  cat > "$dir/xray-config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"listen": "0.0.0.0", "port": 1080, "protocol": "socks", "settings": {"udp": true}},
    {"listen": "0.0.0.0", "port": 8118, "protocol": "http"}
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {"vnext": [{"address": "$host", "port": ${port:-443}, "users": [{"id": "$uuid", "encryption": "none", "flow": "$flow"}]}]},
      "streamSettings": {"network": "$typ", "security": "$sec", $reality "tlsSettings": {"serverName": "$sni", "fingerprint": "$fp"}}
    }
  ]
}
EOF
}

# Resolve a hostname's IPv4 A records (best-effort; dig/getent/host). Used to expand
# the FQDN allow-list into /32 entries at config-generation time.
proxy_resolve_a() {
  local h="$1"
  if command_exists dig;    then dig +short A "$h" 2>/dev/null | grep -E '^[0-9.]+$'
  elif command_exists getent; then getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u
  elif command_exists host;   then host -t A "$h" 2>/dev/null | awk '/has address/{print $NF}'
  fi
}

# Turn a user-supplied WireGuard conf into a firewall/router: pin DNS, add a
# kill-switch (reject any egress not leaving via the tunnel — no leak if it drops),
# and an optional allow-list (drop everything else) of CIDRs plus FQDNs resolved to /32
# at config time (re-run egress config to refresh). Idempotent; wg-quick runs PostUp/PreDown.
harden_wg_conf() {
  local f="$1"; [ -f "$f" ] || return 0
  grep -q 'psai-fw' "$f" 2>/dev/null && return 0
  local dns="${PROXY_DNS:-}" ks="" allow="${PROXY_ALLOW_CIDR:-}"
  if [ -n "${PROXY_ALLOW_FQDN:-}" ]; then
    local d ip
    # shellcheck disable=SC2086
    for d in $PROXY_ALLOW_FQDN; do
      for ip in $(proxy_resolve_a "$d"); do allow="$allow ${ip}/32"; done
    done
    allow="$(printf '%s' "$allow" | tr -s ' ' | sed 's/^ //;s/ $//')"
  fi
  [ "${PROXY_KILLSWITCH:-true}" = "true" ] && ks=1
  awk -v dns="$dns" -v ks="$ks" -v allow="$allow" '
    /^\[Interface\]/ && ins==0 {
      print; print "# psai-fw"
      if (dns != "") print "DNS = " dns
      if (allow != "") { n=split(allow,a," "); for(i=1;i<=n;i++){
        print "PostUp = iptables -I OUTPUT -d " a[i] " -j ACCEPT" } }
      if (ks != "") {
        print "PostUp = iptables -I OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT || true"
        print "PreDown = iptables -D OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT || true"
      }
      ins=1; next
    }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  chmod 600 "$f" 2>/dev/null || true
}

# configure_egress_secrets <slot>  (slot = stack | web). Collects provider config into
# the slot's gateway dir; falls back to tor if required config is missing.
configure_egress_secrets() {
  local slot="$1" mode dir
  case "$slot" in
    stack) mode="$EGRESS_STACK"; dir="$STACK_DIR/gateway-stack" ;;
    web)   mode="$EGRESS_WEB";   dir="$STACK_DIR/gateway-web" ;;
    *) return 0 ;;
  esac
  [ "$mode" != "none" ] || return 0
  mkdir -p "$dir"
  case "$mode" in
    vless)
      local uri; uri="$(cat "$dir/vless-uri.txt" 2>/dev/null || true)"
      [ -z "$uri" ] && [ "$NONINTERACTIVE" != "1" ] && uri="$(ask "$(t q_vless_uri)" '')"
      if [ -z "$uri" ] && [ ! -f "$dir/xray-config.json" ]; then egress_fallback_tor "$slot"; return 0; fi
      [ -n "$uri" ] && { ( umask 077; printf '%s\n' "$uri" > "$dir/vless-uri.txt" ); write_xray_config "$uri" "$dir"; } ;;
    wireguard)
      local src; src="$(cat "$dir/wg-path.txt" 2>/dev/null || true)"
      [ -z "$src" ] && [ "$NONINTERACTIVE" != "1" ] && src="$(ask "$(t q_wg_conf)" '')"
      mkdir -p "$dir/wg_confs"
      if [ -n "$src" ] && [ -f "${src/#\~/$HOME}" ]; then
        cp "${src/#\~/$HOME}" "$dir/wg_confs/wg0.conf"
        ( umask 077; printf '%s\n' "$src" > "$dir/wg-path.txt" )
      fi
      [ -f "$dir/wg_confs/wg0.conf" ] || { egress_fallback_tor "$slot"; return 0; }
      harden_wg_conf "$dir/wg_confs/wg0.conf" ;;
    adguardvpn)
      local u p; u="$(cat "$dir/ag-user.txt" 2>/dev/null || true)"
      if [ -z "$u" ] && [ "$NONINTERACTIVE" != "1" ]; then
        u="$(ask "$(t q_ag_user)" '')"
        printf '  %s: ' "$(t pw_label)"; stty -echo 2>/dev/null; IFS= read -r p || true; stty echo 2>/dev/null; printf '\n'
        [ -n "$u" ] && ( umask 077; printf '%s\n' "$u" > "$dir/ag-user.txt"; printf '%s\n' "$p" > "$dir/ag-pass.txt" )
      fi
      [ -s "$dir/ag-user.txt" ] || { egress_fallback_tor "$slot"; return 0; } ;;
    tailscale)
      local key; key="$(cat "$dir/ts-authkey.txt" 2>/dev/null || true)"
      [ -z "$key" ] && [ "$NONINTERACTIVE" != "1" ] && key="$(ask "$(t q_ts_key)" '')"
      [ -n "$key" ] && ( umask 077; printf '%s\n' "$key" > "$dir/ts-authkey.txt" )
      key="$(cat "$dir/ts-authkey.txt" 2>/dev/null || true)"
      [ -z "$key" ] && { egress_fallback_tor "$slot"; return 0; }
      ( umask 077; printf 'TS_AUTHKEY=%s\nTS_EXTRA_ARGS=\n' "$key" > "$dir/tailscale.env" ) ;;
  esac
}

egress_fallback_tor() {
  printf '%s%s%s\n' "$C_YELLOW" "$(t px_need_cfg)" "$C_RESET"
  case "$1" in stack) EGRESS_STACK="tor" ;; web) EGRESS_WEB="tor" ;; esac
  compute_egress_endpoints
}

# ── compose service emitter ──────────────────────────────────────────────────
# append_proxy_service <slot>  — appends the proxy (and its sidecar) to the compose
# file. proxy-web is published on host loopback; proxy-stack is internal-only.
append_proxy_service() {
  local slot="$1" name mode dir hostport f nets=""
  f="$STACK_DIR/compose/docker-compose.yml"
  case "$slot" in
    stack) name="proxy-stack"; mode="$EGRESS_STACK"; dir="../gateway-stack"; hostport="" ;;
    web)   name="proxy-web";   mode="$EGRESS_WEB";   dir="../gateway-web";   hostport="$EG_HOST_WEB_PORT" ;;
    *) return 0 ;;
  esac
  [ "$mode" != "none" ] || return 0
  # NOTE: proxy-stack stays on the default app network only. It is deliberately NOT joined
  # to ollama-private: bridging it there would give app containers a forward-proxy hop to
  # raw Ollama. Pulling models through the proxy is handled by the one-shot ollama-pull
  # (see append_ollama_service), which runs on the app network instead.
  local iport; iport="$(eg_mode_port "$mode")"; local sc="${name}-http"
  local ports=""; [ -n "$hostport" ] && ports="    ports:
      - \"$(eg_web_bind):${hostport}:${iport}\""
  case "$mode" in
    tor)
      cat >> "$f" <<EOF

  $name:
    image: $TOR_IMAGE
    container_name: ${SAFE_STACK_NAME}-$name
    restart: unless-stopped
$ports
$nets
EOF
      ;;
    vless)
      cat >> "$f" <<EOF

  $name:
    image: $XRAY_IMAGE
    container_name: ${SAFE_STACK_NAME}-$name
    restart: unless-stopped
    command: ["run", "-c", "/etc/xray/config.json"]
    volumes:
      - $dir/xray-config.json:/etc/xray/config.json:ro
$ports
$nets
EOF
      ;;
    wireguard)
      cat >> "$f" <<EOF

  $name:
    image: $WIREGUARD_IMAGE
    container_name: ${SAFE_STACK_NAME}-$name
    restart: unless-stopped
    cap_add: [NET_ADMIN, SYS_MODULE]
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - $dir/wg_confs:/config/wg_confs:ro
$ports
$nets

  $sc:
    image: $HTTP_SIDECAR_IMAGE
    container_name: ${SAFE_STACK_NAME}-$sc
    restart: unless-stopped
    command: ["ANY"]
    network_mode: "service:$name"
    depends_on: [$name]
EOF
      ;;
    adguardvpn)
      cat >> "$f" <<EOF

  $name:
    image: $ADGUARDVPN_IMAGE
    container_name: ${SAFE_STACK_NAME}-$name
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices:
      - /dev/net/tun
    volumes:
      - $dir/adguardvpn:/opt/adguardvpn_cli
$ports
$nets

  $sc:
    image: $HTTP_SIDECAR_IMAGE
    container_name: ${SAFE_STACK_NAME}-$sc
    restart: unless-stopped
    command: ["ANY"]
    network_mode: "service:$name"
    depends_on: [$name]
EOF
      ;;
    tailscale)
      cat >> "$f" <<EOF

  $name:
    image: $TAILSCALE_IMAGE
    container_name: ${SAFE_STACK_NAME}-$name
    restart: unless-stopped
    cap_add: [NET_ADMIN, SYS_MODULE]
    devices:
      - /dev/net/tun
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
    env_file:
      - $dir/tailscale.env
    volumes:
      - ../data/tailscale:/var/lib/tailscale
$ports
$nets

  $sc:
    image: $HTTP_SIDECAR_IMAGE
    container_name: ${SAFE_STACK_NAME}-$sc
    restart: unless-stopped
    command: ["ANY"]
    network_mode: "service:$name"
    depends_on: [$name]
EOF
      ;;
  esac
}

# ── install-time prompts ──────────────────────────────────────────────────────
choose_egress_slot() {
  local slot="$1" def="$2" c
  menu_line "$(t px_mode)" 0 "$(t px_none)" 1 "$(t px_tor)" 2 "$(t px_wireguard)" 3 "$(t px_vless)"
  menu_line "" 4 "$(t px_adguard)" 5 "$(t px_tailscale)"
  c="$(ask "$(t px_pick)" "$def")"
  local mode
  case "$(printf '%s' "$c" | tr -d '[][:space:]' | tr 'A-Z' 'a-z')" in
    1|tor) mode="tor" ;; 2|wireguard|wg) mode="wireguard" ;; 3|vless) mode="vless" ;;
    4|adguardvpn|adguard) mode="adguardvpn" ;; 5|tailscale|ts) mode="tailscale" ;;
    *) mode="none" ;;
  esac
  case "$slot" in stack) EGRESS_STACK="$mode" ;; web) EGRESS_WEB="$mode" ;; esac
}

# Both proxies are OFFERED at install; default DIRECT (none). Presets when enabled:
# proxy-stack → Tor, proxy-web → WireGuard.
ask_proxies() {
  printf '\n%s%s%s\n' "$C_B" "$(t px_title)" "$C_RESET"
  printf '  %s%s%s\n  %s%s%s\n' "$C_DIM" "$(t px_stack)" "$C_RESET" "$C_DIM" "$(t px_web)" "$C_RESET"
  if confirm "$(t px_stack_q)" 'N'; then
    choose_egress_slot stack '1'; configure_egress_secrets stack
    if confirm "$(t px_local_q)" 'N'; then ROUTE_LOCAL_LLM="true"; else ROUTE_LOCAL_LLM="false"; fi
  else EGRESS_STACK="none"; fi
  if confirm "$(t px_web_q)" 'N'; then
    choose_egress_slot web '2'; configure_egress_secrets web
  else EGRESS_WEB="none"; fi
  compute_egress_endpoints
  return 0   # never let a trailing non-zero abort the installer under set -e
}
