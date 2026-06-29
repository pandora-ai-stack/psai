# ───────────────────────────── config (.stack.env) ─────────────────────────────
load_config() {
  if [ -f "$SCRIPT_DIR/.stack.env" ]; then CONFIG_FILE="$SCRIPT_DIR/.stack.env"
  elif [ -f "$SCRIPT_DIR/../.stack.env" ]; then CONFIG_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/.stack.env"
  elif [ -n "${STACK_DIR:-}" ] && [ -f "$STACK_DIR/.stack.env" ]; then CONFIG_FILE="$STACK_DIR/.stack.env"
  else return 1; fi
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  # Backfill defaults for keys added across versions (forward/backward compatible).
  : "${NODE_MODE:=single}"; : "${DEPLOY_PROFILE:=local}"; : "${OPENHANDS_IMAGE:=}"
  : "${ENABLE_OPENWEBUI:=true}"; : "${ENABLE_AGENTS:=true}"; : "${ENABLE_SEARCH:=true}"
  : "${ENABLE_GIT:=true}"; : "${ENABLE_QDRANT:=false}"; : "${ENABLE_MCP:=false}"; : "${ENABLE_EMBEDDINGS:=false}"; : "${ENABLE_PENTEST:=false}"
  : "${RAG_MODE:=off}"; : "${ENABLE_EMBED_SVC:=false}"; : "${ENABLE_INGEST:=false}"; : "${RAG_HYBRID:=false}"
  : "${EMBED_SVC_MODEL:=BAAI/bge-m3}"; : "${RERANK_MODEL:=BAAI/bge-reranker-v2-m3}"
  : "${EMBED_URL:=}"; : "${EMBED_MODEL:=}"; : "${EMBED_API_KEY:=}"; : "${EMBED_SVC_PORT:=7997}"
  : "${MEMORY_MODE:=stub}"; : "${MEMORY_LLM_URL:=}"; : "${MEMORY_LLM_KEY:=}"; : "${MEMORY_LLM_MODEL:=gpt-4o-mini}"
  : "${MEM0_API_KEY:=}"; : "${MEM0_MCP_URL:=}"; : "${MEMORY_PORT:=8000}"
  : "${LOCAL_LLM:=none}"; : "${OLLAMA_MODEL:=llama3.2:3b}"; : "${OLLAMA_EMBED_MODEL:=nomic-embed-text}"; : "${OLLAMA_PULL_VIA_PROXY:=false}"; : "${GPU_MODE:=}"
  : "${MCP_GATEWAY:=false}"; : "${MCP_GATEWAY_SERVERS:=fetch,context7}"; : "${MCP_GATEWAY_PORT:=8811}"
  : "${LLM_GATEWAY:=false}"; : "${ENABLE_EVAL:=false}"
  : "${AGENTS_DOCKER:=false}"; : "${AGENT_WEB:=true}"; : "${OPENHANDS_DOCKER_MODE:=host}"
  : "${SECURITY_PROFILE:=default}"
  : "${SEC_SEAL:=}"; : "${SEC_FIREWALL:=}"; : "${SEC_WATCHDOG:=}"; : "${SEC_CIS:=}"; : "${SEC_NOSSH:=}"; : "${SEC_FAIL2BAN:=}"; : "${SEC_TPM:=}"
  : "${SEAL_ENABLED:=false}"; : "${SEAL_MODE:=auto}"
  : "${EGRESS_STACK:=none}"; : "${EGRESS_WEB:=none}"; : "${STACK_VIA_PROXY:=true}"; : "${WEB_VIA_PROXY:=true}"; : "${ROUTE_LOCAL_LLM:=false}"
  : "${LOG_RETENTION:=6m}"; : "${TLS_MODE:=le}"; : "${OWN_CERT_PATH:=}"; : "${OWN_KEY_PATH:=}"
  : "${PUBLIC_DOMAIN:=}"; : "${ACME_EMAIL:=}"; : "${ENABLE_FAIL2BAN:=false}"
  : "${ISOLATE_AGENTS:=false}"; : "${ISOLATE_GIT:=false}"; : "${SHARED_MEMORY:=false}"
  : "${QDRANT_DOMAIN:=}"; : "${OPENHANDS_LLM_MODEL:=}"
  # Backfill NO_DOMAIN (added later): if it was never persisted, infer it from the saved
  # zone — a no-domain install records DOMAIN_ZONE=localhost. Prevents a rebuild from
  # silently switching a localhost-ports stack back to a domain/80/443 Caddy.
  : "${NO_DOMAIN:=false}"; : "${DUAL_ACCESS:=false}"
  [ "${DOMAIN_ZONE:-}" = "localhost" ] && NO_DOMAIN="true"
  : "${DOCKER_CONTEXT_PIN:=}"
  if [ "${LANG_FROM_ENV:-0}" != "1" ] && [ -n "${UI_LANG_SAVED:-}" ]; then UI_LANG="$UI_LANG_SAVED"; fi
  return 0
}

# Single-quote-escape a value so `.stack.env` is safe to source: every value becomes a
# literal single-quoted string, and any embedded `'` is rewritten as the `'\''` idiom.
# Without this, a value containing ", $(...), backticks or a newline would execute (or
# corrupt the config) when load_config sources the file.
shq() {
  case $1 in
    *\'*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *)    printf "'%s'" "$1" ;;
  esac
}
# kv KEY VALUE -> `KEY='escaped-value'` (safe to source).
kv() { printf '%s=%s\n' "$1" "$(shq "$2")"; }

save_config() {
  mkdir -p "$STACK_DIR"
  umask 077
  {
    kv STACK_VERSION "$STACK_VERSION"
    kv UI_LANG_SAVED "$UI_LANG"
    kv NODE_MODE "$NODE_MODE"
    kv DEPLOY_PROFILE "$DEPLOY_PROFILE"
    kv STACK_NAME "$STACK_NAME"
    kv SAFE_STACK_NAME "$SAFE_STACK_NAME"
    kv STACK_DIR "$STACK_DIR"
    kv ADMIN_USER "$ADMIN_USER"
    kv ENABLE_OPENWEBUI "$ENABLE_OPENWEBUI"
    kv ENABLE_AGENTS "$ENABLE_AGENTS"
    kv ENABLE_SEARCH "$ENABLE_SEARCH"
    kv ENABLE_GIT "$ENABLE_GIT"
    kv ENABLE_QDRANT "$ENABLE_QDRANT"
    kv ENABLE_MCP "$ENABLE_MCP"
    kv ENABLE_EMBEDDINGS "$ENABLE_EMBEDDINGS"
    kv RAG_MODE "$RAG_MODE"
    kv ENABLE_EMBED_SVC "$ENABLE_EMBED_SVC"
    kv ENABLE_INGEST "$ENABLE_INGEST"
    kv RAG_HYBRID "$RAG_HYBRID"
    kv EMBED_SVC_MODEL "$EMBED_SVC_MODEL"
    kv RERANK_MODEL "$RERANK_MODEL"
    kv EMBED_URL "$EMBED_URL"
    kv EMBED_MODEL "$EMBED_MODEL"
    kv EMBED_API_KEY "$EMBED_API_KEY"
    kv MEMORY_MODE "$MEMORY_MODE"
    kv MEMORY_LLM_URL "$MEMORY_LLM_URL"
    kv MEMORY_LLM_KEY "$MEMORY_LLM_KEY"
    kv MEMORY_LLM_MODEL "$MEMORY_LLM_MODEL"
    kv MEM0_API_KEY "$MEM0_API_KEY"
    kv MEM0_MCP_URL "$MEM0_MCP_URL"
    kv LOCAL_LLM "$LOCAL_LLM"
    kv OLLAMA_MODEL "$OLLAMA_MODEL"
    kv OLLAMA_EMBED_MODEL "$OLLAMA_EMBED_MODEL"
    kv OLLAMA_PULL_VIA_PROXY "$OLLAMA_PULL_VIA_PROXY"
    kv GPU_MODE "$GPU_MODE"
    kv MCP_GATEWAY "$MCP_GATEWAY"
    kv MCP_GATEWAY_SERVERS "$MCP_GATEWAY_SERVERS"
    kv LLM_GATEWAY "$LLM_GATEWAY"
    kv ENABLE_EVAL "$ENABLE_EVAL"
    kv ENABLE_PENTEST "$ENABLE_PENTEST"
    kv AGENTS_DOCKER "$AGENTS_DOCKER"
    kv AGENT_WEB "$AGENT_WEB"
    kv OPENHANDS_DOCKER_MODE "$OPENHANDS_DOCKER_MODE"
    kv OPENHANDS_LLM_MODEL "$OPENHANDS_LLM_MODEL"
    kv SECURITY_PROFILE "$SECURITY_PROFILE"
    kv SEC_SEAL "$SEC_SEAL"
    kv SEC_FIREWALL "$SEC_FIREWALL"
    kv SEC_WATCHDOG "$SEC_WATCHDOG"
    kv SEC_CIS "$SEC_CIS"
    kv SEC_NOSSH "$SEC_NOSSH"
    kv SEC_FAIL2BAN "$SEC_FAIL2BAN"
    kv SEC_TPM "$SEC_TPM"
    kv SEAL_ENABLED "$SEAL_ENABLED"
    kv SEAL_MODE "$SEAL_MODE"
    kv EGRESS_STACK "$EGRESS_STACK"
    kv EGRESS_WEB "$EGRESS_WEB"
    kv STACK_VIA_PROXY "$STACK_VIA_PROXY"
    kv WEB_VIA_PROXY "$WEB_VIA_PROXY"
    kv ROUTE_LOCAL_LLM "$ROUTE_LOCAL_LLM"
    kv LOG_RETENTION "$LOG_RETENTION"
    kv TLS_MODE "$TLS_MODE"
    kv OWN_CERT_PATH "$OWN_CERT_PATH"
    kv OWN_KEY_PATH "$OWN_KEY_PATH"
    kv PUBLIC_DOMAIN "$PUBLIC_DOMAIN"
    kv ACME_EMAIL "$ACME_EMAIL"
    kv ENABLE_FAIL2BAN "$ENABLE_FAIL2BAN"
    kv NO_DOMAIN "$NO_DOMAIN"
    kv DUAL_ACCESS "$DUAL_ACCESS"
    kv DOCKER_CONTEXT_PIN "$DOCKER_CONTEXT_PIN"
    kv DOMAIN_ZONE "$DOMAIN_ZONE"
    kv DOMAIN_BASE "$DOMAIN_BASE"
    kv PSAI_DOMAIN "$PSAI_DOMAIN"
    kv AGENTS_DOMAIN "$AGENTS_DOMAIN"
    kv GIT_DOMAIN "$GIT_DOMAIN"
    kv GIT_SSH_HOST "$GIT_SSH_HOST"
    kv GIT_SSH_PORT "$GIT_SSH_PORT"
    kv QDRANT_DOMAIN "$QDRANT_DOMAIN"
    kv CERT_YEARS "$CERT_YEARS"
    kv ISOLATE_AGENTS "$ISOLATE_AGENTS"
    kv ISOLATE_GIT "$ISOLATE_GIT"
    kv SHARED_MEMORY "$SHARED_MEMORY"
    kv AGENT_EGRESS "$AGENT_EGRESS"
    kv AGENT_INDEX "$AGENT_INDEX"
    kv AGENT_DOMAIN "$AGENT_DOMAIN"
    kv AGENT_SUB "$AGENT_SUB"
    kv AGENT_GIT_SUB "$AGENT_GIT_SUB"
    kv AGENT_ACME_EMAIL "$AGENT_ACME_EMAIL"
    kv AGENT_SERVERS "$AGENT_SERVERS"
    kv SSH_FAILBACK_MIN "$SSH_FAILBACK_MIN"
    kv AGENT_PUBLIC_IP "$AGENT_PUBLIC_IP"
    kv AGENT_WG_IP "$AGENT_WG_IP"
    kv RA_HOST "$RA_HOST"
    kv RA_PORT "$RA_PORT"
    kv RA_USER "$RA_USER"
    kv REMOTE_WG_NET "$REMOTE_WG_NET"
    kv REMOTE_WG_PORT "$REMOTE_WG_PORT"
    kv OPENHANDS_IMAGE "$OPENHANDS_IMAGE"
  } > "$STACK_DIR/.stack.env"
  chmod 600 "$STACK_DIR/.stack.env" 2>/dev/null || true
}

# ───────────────────────────── secrets ─────────────────────────────
random_secret() { openssl rand -base64 32 | tr -d '\n'; }
searxng_secret_gen() { openssl rand -hex 48; }
api_key_gen() { printf 'sk-%s' "$(openssl rand -hex 32)"; }
# Alphanumeric admin password (easy to type). Finite source (openssl) + a bash slice —
# NOT `tr </dev/urandom | head -c`, which SIGPIPEs tr and aborts install under set -e.
admin_pw_gen() { local s; s="$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9')"; printf '%s' "${s:0:20}"; }

secrets_file() { printf '%s/secrets/passwords.txt' "$STACK_DIR"; }

# secret_get <key> [generator] -> returns a named secret, creating it idempotently.
# When stack-vault is up it is the store (secrets live in RAM, not in a file on disk);
# otherwise fall back to the file-based secrets/passwords.txt.
secret_get() {
  local key="$1" gen="${2:-random_secret}" file val
  if vault_enabled && vault_up; then
    val="$(vault_get "$key")"
    if [ -z "$val" ]; then val="$($gen)"; printf '%s' "$val" | vault_put "$key"; fi
    printf '%s' "$val"; return 0
  fi
  file="$(secrets_file)"; mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || ( umask 077; printf '# psai — generated secrets. Keep this file safe.\n' > "$file" )
  val="$(sed -n "s/^${key}=//p" "$file" | head -1)"
  if [ -z "$val" ]; then val="$($gen)"; printf '%s=%s\n' "$key" "$val" >> "$file"; fi
  chmod 600 "$file" 2>/dev/null || true
  printf '%s' "$val"
}

# secret_set <key> : store/overwrite a named secret (value on stdin). Routes to the vault
# when it's up (RAM/secretmem) exactly like secret_get, otherwise the 0600 passwords.txt —
# so a later `rebuild` reads back the same value. Used to pin an operator-chosen password.
secret_set() {
  local key="$1" val file tmp; val="$(cat)"
  if vault_enabled && vault_up; then printf '%s' "$val" | vault_put "$key"; return 0; fi
  file="$(secrets_file)"; mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || ( umask 077; printf '# psai — generated secrets. Keep this file safe.\n' > "$file" )
  tmp="$file.tmp.$$"
  grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

# bcrypt hash for Caddy basic_auth. The plaintext is fed on STDIN (htpasswd -i), never as a
# command-line argument — `caddy hash-password --plaintext "$pass"` and `htpasswd -nb … "$pass"`
# both leak the password into `ps` / docker events for the life of the container. Cost 12.
# Normalize the htpasswd `$2y$` prefix to `$2b$` — Go's bcrypt (Caddy) rejects `$2y$`.
hash_password() {
  local pass="$1" h
  h="$(printf '%s' "$pass" | docker run -i --rm "$HTTPD_IMAGE" htpasswd -niBC 12 x 2>/dev/null | sed 's/^x://')"
  printf '%s' "${h/\$2y\$/\$2b\$}"
}

prepare_dirs_and_secrets() {
  mkdir -p \
    "$STACK_DIR/bin" "$STACK_DIR/compose" "$STACK_DIR/backups" \
    "$STACK_DIR/secrets" "$STACK_DIR/secrets/certificates" "$STACK_DIR/secrets/wg" \
    "$STACK_DIR/data/openwebui" "$STACK_DIR/data/openhands-state" "$STACK_DIR/data/projects" \
    "$STACK_DIR/data/searxng" "$STACK_DIR/data/forgejo" "$STACK_DIR/data/qdrant" "$STACK_DIR/data/embeddings" "$STACK_DIR/data/pentest" \
    "$STACK_DIR/data/embed" "$STACK_DIR/data/ingest" "$STACK_DIR/data/ingest/tmp" "$STACK_DIR/data/memory" "$STACK_DIR/data/ollama" "$STACK_DIR/data/langfuse-db" \
    "$STACK_DIR/data/logs" "$STACK_DIR/data/tailscale" \
    "$STACK_DIR/data/agents" "$STACK_DIR/data/ai_agents_public" \
    "$STACK_DIR/caddy/data" "$STACK_DIR/caddy/data/logs/caddy" "$STACK_DIR/caddy/config" \
    "$STACK_DIR/gateway-stack" "$STACK_DIR/gateway-web" \
    "$STACK_DIR/openhands-sandbox" "$STACK_DIR/openhands-config" "$STACK_DIR/mcp"
  chmod 700 "$STACK_DIR/secrets" 2>/dev/null || true
  chmod 1777 "$STACK_DIR/data/ingest/tmp" 2>/dev/null || true
  # Caddy basic-auth creds are typed into a browser prompt → generate them alphanumeric
  # (admin_pw_gen) so they're typeable; app-account secrets stay full-entropy base64.
  secret_get searxng_secret searxng_secret_gen >/dev/null
  [ "$ENABLE_AGENTS"   = "true" ] && secret_get agents_basic_auth admin_pw_gen >/dev/null
  [ "$ENABLE_OPENWEBUI" = "true" ] && secret_get webui_basic_auth admin_pw_gen >/dev/null
  [ "$ENABLE_QDRANT"   = "true" ] && secret_get qdrant_basic_auth admin_pw_gen >/dev/null
  [ "$ENABLE_GIT"      = "true" ] && secret_get forgejo_admin     >/dev/null
  ollama_enabled && secret_get ollama_api_key api_key_gen >/dev/null
  # If the operator chose their own admin password, make it the actual basic-auth gate for
  # the web UIs (Open WebUI/OpenHands/Qdrant) instead of a generated one. It overwrites the
  # generated basic_auth secret in the same store (the vault when sealed) — never written
  # in plaintext next to the config. Without this the chosen password was collected and
  # silently dropped.
  if [ -n "${ADMIN_PASSWORD_PLAIN:-}" ]; then
    [ "$ENABLE_OPENWEBUI" = "true" ] && printf '%s' "$ADMIN_PASSWORD_PLAIN" | secret_set webui_basic_auth
    [ "$ENABLE_AGENTS"    = "true" ] && printf '%s' "$ADMIN_PASSWORD_PLAIN" | secret_set agents_basic_auth
    [ "$ENABLE_QDRANT"    = "true" ] && printf '%s' "$ADMIN_PASSWORD_PLAIN" | secret_set qdrant_basic_auth
  fi
  return 0
}

# Open WebUI CORS / allowed origins (used by some integrations).
build_allowed_origins() {
  local origins="https://$PSAI_DOMAIN,http://localhost,http://127.0.0.1"
  [ "$ENABLE_AGENTS" = "true" ] && origins="$origins,https://$AGENTS_DOMAIN"
  [ "$ENABLE_GIT" = "true" ] && origins="$origins,https://$GIT_DOMAIN"
  printf '%s' "$origins"
}
