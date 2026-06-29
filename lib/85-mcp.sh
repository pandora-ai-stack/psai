# ───────────────────────────── qdrant + mcp ─────────────────────────────
# Qdrant = optional SHARED vector memory for Open WebUI + OpenHands (+ agents over
# WG in multi-node). When enabled you can also bring up OUR OWN MCP server — a
# working stub today (health + SSE placeholder, wired to Qdrant), so the only thing
# left to add later is the actual tool logic in mcp/server.py.
mcp_enabled() { [ "${ENABLE_MCP:-false}" = "true" ] && [ "${ENABLE_QDRANT:-false}" = "true" ]; }
MCP_SSE_URL="http://mcp:9000/sse"
QDRANT_URL="http://qdrant:6333"

append_qdrant_service() {
  [ "$ENABLE_QDRANT" = "true" ] || return 0
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  qdrant:
    image: $QDRANT_IMAGE
    container_name: ${SAFE_STACK_NAME}-qdrant
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    environment:
      - QDRANT__TELEMETRY_DISABLED=true
    volumes:
      - ../data/qdrant:/qdrant/storage
    healthcheck:
      test: ["CMD-SHELL", "bash -c ':> /dev/tcp/127.0.0.1/6333' 2>/dev/null || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 10
EOF
}

# ───────────────────────────── RAG-plus: embeddings/reranker + ingest ─────────────────────────────
embed_enabled()  { [ "${ENABLE_EMBED_SVC:-false}" = "true" ]; }
ingest_enabled() { [ "${ENABLE_INGEST:-false}" = "true" ]; }

# Local embeddings + reranker (Infinity). OpenAI-compatible /v1/embeddings (used by Open WebUI
# RAG and the MCP memory) plus a /rerank endpoint. CPU + arm64; models pulled from HuggingFace
# (egress via proxy-stack when configured). Internal only — reached as embed:<port>.
append_embed_service() {
  embed_enabled || return 0
  local model_args
  if [ -n "${RERANK_MODEL:-}" ]; then
    model_args="[\"v2\", \"--model-id\", \"$EMBED_SVC_MODEL\", \"--model-id\", \"$RERANK_MODEL\", \"--port\", \"$EMBED_SVC_PORT\", \"--host\", \"0.0.0.0\"]"
  else
    model_args="[\"v2\", \"--model-id\", \"$EMBED_SVC_MODEL\", \"--port\", \"$EMBED_SVC_PORT\", \"--host\", \"0.0.0.0\"]"
  fi
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  embed:
    image: $INFINITY_IMAGE
    container_name: ${SAFE_STACK_NAME}-embed
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    command: $model_args
    environment:
      - HF_HOME=/cache
$(stack_env_lines)
    volumes:
      - ../data/embed:/cache
EOF
}

# Document ingest: Docling (structure/tables/formulas/reading-order/OCR → Markdown/JSON,
# reached as ingest-docling:5001) with Apache Tika as a broad-format fallback
# (ingest-tika:9998). Open WebUI's content extraction points at Docling (see compose_openwebui).
append_ingest_service() {
  ingest_enabled || return 0
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  ingest-docling:
    image: $DOCLING_IMAGE
    container_name: ${SAFE_STACK_NAME}-ingest-docling
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    environment:
      - DOCLING_SERVE_ENABLE_UI=0
      - TMPDIR=/cache/tmp
      - TMP=/cache/tmp
      - TEMP=/cache/tmp
      - HF_HOME=/cache
$(stack_env_lines)
    volumes:
      - ../data/ingest:/cache

  ingest-tika:
    image: $TIKA_IMAGE
    container_name: ${SAFE_STACK_NAME}-ingest-tika
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
EOF
}

# ───────────────────────────── memory backends (PSAI_MEMORY) ─────────────────────────────
# Self-host graph+vector memory (Cognee). Embedded stores (SQLite/LanceDB/Kuzu) — no extra DB.
# Needs an LLM to extract the graph (MEMORY_LLM_*); embeddings come from the local Infinity
# service when RAG-plus is on, else from the same OpenAI-compatible endpoint. SSE MCP on :8000.
append_cognee_service() {
  [ "${MEMORY_MODE:-stub}" = "cognee" ] || return 0
  # Embeddings for cognee. With the bundled Ollama use cognee's OLLAMA provider (NOT openai):
  # the openai path forces TikToken, which can't tokenise a local model name (nomic/bge) and
  # aborts cognify — the ollama provider uses HUGGINGFACE_TOKENIZER instead (cognee #3353).
  # Set the matching tokenizer + dims (defaults are for nomic-embed-text; override if you
  # change PSAI_OLLAMA_EMBED_MODEL). Infinity (bge) is reused only when there's no Ollama.
  # cognee embeddings via FASTEMBED — runs the model IN cognee (no external endpoint, no API
  # key, no tiktoken/HF-tokeniser mismatch). Live e2e showed cognee's ollama/openai embedding
  # providers are brittle (TikToken KeyError on non-OpenAI names; 422/405 on the ollama
  # endpoint), while the LLM graph-build over Ollama works. fastembed sidesteps all of that;
  # Infinity/Ollama stay the embedders for Open WebUI RAG, not for cognee.
  # cognee/cognee-mcp:main validates these four together: setting EMBEDDING_PROVIDER/MODEL/
  # DIMENSIONS without HUGGINGFACE_TOKENIZER aborts boot with a pydantic ValidationError
  # ("set some but not all"). For fastembed the tokeniser is the same HF model id.
  local emb="      - EMBEDDING_PROVIDER=fastembed
      - EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
      - EMBEDDING_DIMENSIONS=384
      - HUGGINGFACE_TOKENIZER=sentence-transformers/all-MiniLM-L6-v2"
  # cognee's two clients want DIFFERENT Ollama paths: the LLM (instructor/openai client) needs
  # the /v1 OpenAI-compat path (native → 404); the embedding (litellm ollama) needs the NATIVE
  # base (/v1 → 422). So: LLM endpoint = …/v1, embedding endpoint = … (set in the emb block).
  local llm_ep=""
  if ollama_enabled; then llm_ep="      - LLM_ENDPOINT=http://ollama:11434/v1"
  elif [ -n "${MEMORY_LLM_URL:-}" ]; then llm_ep="      - LLM_ENDPOINT=$MEMORY_LLM_URL"; fi
  # Bundled Ollama → use cognee's ollama LLM provider too (so its tokeniser path matches).
  local llm_prov=""; ollama_enabled && llm_prov="      - LLM_PROVIDER=ollama"
  # A local CPU LLM cold-loads the model on the first call, which routinely blows cognee's 30s
  # startup connection-test even though the endpoint is fine — skip it there.
  local skip_test=""; ollama_enabled && skip_test="      - COGNEE_SKIP_CONNECTION_TEST=true"
  local llm_key_env=""
  ollama_enabled || llm_key_env="      - LLM_API_KEY=${MEMORY_LLM_KEY:-}"
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  memory:
    image: $COGNEE_IMAGE
    container_name: ${SAFE_STACK_NAME}-memory
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    env_file:
      - .runtime.env
    environment:
      - TRANSPORT_MODE=sse
      - HOST=0.0.0.0
      # cognee-mcp keeps DNS-rebinding protection on and only trusts localhost by default,
      # so an agent dialling http://memory:8000/sse gets a 421. Allow the in-network host
      # (service name + container alias) so OpenHands/Open WebUI can actually reach it.
      - MCP_ALLOWED_HOSTS=memory:*,${SAFE_STACK_NAME}-memory:*
      - LLM_MODEL=$MEMORY_LLM_MODEL
$llm_prov
$llm_ep
$skip_test
$llm_key_env
      - DATA_ROOT_DIRECTORY=/cognee/data
      - SYSTEM_ROOT_DIRECTORY=/cognee/system
$emb
$(stack_env_lines)
    volumes:
      - ../data/memory:/cognee
EOF
}

# Temporal knowledge-graph memory (Graphiti on FalkorDB). FIRST CUT — verify the FalkorDB
# env against the image before relying on it; needs an LLM (MEMORY_LLM_*). SSE MCP on :8000.
append_graphiti_service() {
  [ "${MEMORY_MODE:-stub}" = "graphiti" ] || return 0
  local llm_ep=""; [ -n "${MEMORY_LLM_URL:-}" ] && llm_ep="      - OPENAI_BASE_URL=$MEMORY_LLM_URL"
  local llm_key_env=""
  ollama_enabled || llm_key_env="      - OPENAI_API_KEY=${MEMORY_LLM_KEY:-}"
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  falkordb:
    image: $FALKORDB_IMAGE
    container_name: ${SAFE_STACK_NAME}-falkordb
    restart: unless-stopped
    volumes:
      - ../data/memory:/data

  memory:
    image: $GRAPHITI_IMAGE
    container_name: ${SAFE_STACK_NAME}-memory
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    env_file:
      - .runtime.env
    environment:
      - MODEL_NAME=$MEMORY_LLM_MODEL
      - FALKORDB_URI=redis://falkordb:6379
      - FALKORDB_PASSWORD=
      - FALKORDB_DATABASE=default_db
$llm_ep
$llm_key_env
$(stack_env_lines)
    depends_on: [falkordb]
EOF
}

# Bundled local LLM (Ollama): OpenAI-compatible at ollama:11434, but `ollama` is
# an auth proxy. Raw Ollama is `ollama-raw` on a private Docker network, so other
# services cannot bypass the Bearer-token check. A one-shot `ollama-pull` provisions
# models by talking to raw Ollama from that private network.
write_ollama_proxy_files() {
  ollama_enabled || return 0
  mkdir -p "$STACK_DIR/ollama-proxy"
  cat > "$STACK_DIR/ollama-proxy/ollama_auth_proxy.py" <<'EOF'
#!/usr/bin/env python3
"""Bearer-token gate in front of Ollama.

Only this proxy joins the app network. The raw Ollama daemon stays on
ollama-private, so app containers cannot bypass the Authorization check.
"""
import os
import socket
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PORT = int(os.environ.get("OLLAMA_PROXY_PORT", "11434"))
TOKEN = os.environ.get("OLLAMA_API_KEY", "")
UPSTREAM = os.environ.get("OLLAMA_UPSTREAM", "http://ollama-raw:11434").rstrip("/")
TIMEOUT = int(os.environ.get("OLLAMA_PROXY_TIMEOUT", "900"))
HOP_BY_HOP = {
    "authorization",
    "connection",
    "content-length",
    "host",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _plain(self, status, body):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _authorized(self):
        if not TOKEN:
            return False
        return self.headers.get("Authorization", "") == "Bearer " + TOKEN

    def _forward(self):
        if not TOKEN:
            self._plain(503, "ollama auth token is not configured\n")
            return
        if not self._authorized():
            self._plain(401, "unauthorized\n")
            return

        length = self.headers.get("Content-Length")
        body = self.rfile.read(int(length)) if length else None
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_BY_HOP
        }
        headers["X-Forwarded-For"] = self.client_address[0]
        req = urllib.request.Request(
            UPSTREAM + self.path,
            data=body,
            headers=headers,
            method=self.command,
        )
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                self.send_response(resp.status)
                for key, value in resp.headers.items():
                    if key.lower() not in HOP_BY_HOP:
                        self.send_header(key, value)
                self.end_headers()
                if self.command == "HEAD":
                    return
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except urllib.error.HTTPError as exc:
            self.send_response(exc.code)
            for key, value in exc.headers.items():
                if key.lower() not in HOP_BY_HOP:
                    self.send_header(key, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(exc.read())
        except (urllib.error.URLError, socket.timeout, OSError) as exc:
            self._plain(502, "ollama upstream unavailable: %s\n" % exc)

    def do_GET(self): self._forward()
    def do_POST(self): self._forward()
    def do_PUT(self): self._forward()
    def do_PATCH(self): self._forward()
    def do_DELETE(self): self._forward()
    def do_OPTIONS(self): self._forward()
    def do_HEAD(self): self._forward()


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
EOF
  chmod 600 "$STACK_DIR/ollama-proxy/ollama_auth_proxy.py" 2>/dev/null || true
}

append_ollama_service() {
  ollama_enabled || return 0
  local pulls="ollama pull $OLLAMA_MODEL" need_embed="false"
  { ! embed_enabled && memory_self_host; } && need_embed="true"
  case "${EMBED_URL:-}" in http://ollama:11434*) need_embed="true" ;; esac
  if [ "$need_embed" = "true" ] && [ "$OLLAMA_EMBED_MODEL" != "$OLLAMA_MODEL" ]; then
    pulls="$pulls; ollama pull $OLLAMA_EMBED_MODEL"
  fi
  # NVIDIA GPU passthrough (Linux + nvidia container toolkit). On macOS GPU_MODE is always none.
  local gpu=""
  [ "${GPU_MODE:-none}" = "nvidia" ] && gpu="    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]"
  # Pull egress. Default: ollama-raw reaches the model registry directly over its private
  # network. With OLLAMA_PULL_VIA_PROXY=true the raw daemon stays fully isolated and a
  # one-shot puller runs its OWN daemon on the app network (where proxy-stack lives),
  # writing models into the shared volume. That keeps proxy-stack OFF ollama-private, so
  # no app container can use it as a forward-proxy hop to reach raw Ollama unauthenticated.
  local pull_env pull_net pull_cmd pull_vol=""
  if egress_stack_enabled && stack_via_proxy && [ "${OLLAMA_PULL_VIA_PROXY:-false}" = "true" ]; then
    pull_env="    environment:
$(stack_env_lines)"
    pull_net="    networks:
      - default"
    pull_vol="    volumes:
      - ../data/ollama:/root/.ollama"
    pull_cmd='["/bin/sh","-c","ollama serve >/tmp/serve.log 2>&1 & sleep 4; '"$pulls"'"]'
  else
    pull_env="    environment:
      - OLLAMA_HOST=ollama-raw:11434"
    pull_net="    networks:
      - ollama-private"
    pull_cmd='["/bin/sh","-c","sleep 6; '"$pulls"'"]'
  fi
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  ollama-raw:
    image: $OLLAMA_IMAGE
    container_name: ${SAFE_STACK_NAME}-ollama-raw
    restart: unless-stopped
    env_file:
      - .runtime.env
$gpu
    volumes:
      - ../data/ollama:/root/.ollama
    networks:
      - ollama-private

  ollama:
    image: $MCP_IMAGE
    container_name: ${SAFE_STACK_NAME}-ollama
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    env_file:
      - .runtime.env
    command: ["python", "/app/ollama_auth_proxy.py"]
    environment:
      - OLLAMA_UPSTREAM=http://ollama-raw:11434
      - OLLAMA_PROXY_PORT=11434
    volumes:
      - ../ollama-proxy/ollama_auth_proxy.py:/app/ollama_auth_proxy.py:ro
    depends_on: [ollama-raw]
    networks:
      default:
      ollama-private:

  ollama-pull:
    image: $OLLAMA_IMAGE
    container_name: ${SAFE_STACK_NAME}-ollama-pull
    restart: "no"
    env_file:
      - .runtime.env
$pull_env
    entrypoint: $pull_cmd
    depends_on: [ollama-raw]
$pull_vol
$pull_net
EOF
}

# Docker MCP Gateway: one SSE endpoint that proxies a verified, isolated allowlist of catalog
# MCP servers, with image-signature verification. NEEDS the Docker socket (it spawns the server
# containers) — that's host-level control, so it's opt-in and trusted-hosts-only.
append_mcp_gateway_service() {
  mcp_gateway_enabled || return 0
  [ -n "${DOCKER_SOCK:-}" ] || detect_docker_sock
  local proxy_env=""
  egress_stack_enabled && stack_via_proxy && proxy_env="    environment:
$(stack_env_lines)"
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  mcp-gateway:
    image: $MCP_GATEWAY_IMAGE
    container_name: ${SAFE_STACK_NAME}-mcp-gateway
    restart: unless-stopped
    # Pin the SSE Bearer token (MCP_GATEWAY_AUTH_TOKEN from the runtime secrets) instead of
    # letting the gateway mint a random one at boot — that random token is unknown at config
    # time, so the agents and the mcpo bridge would get 401. With a known token the gateway
    # stays authenticated and its clients present it (see write_openhands_mcp_config / mcpo).
    env_file:
      - .runtime.env
    command: ["--transport=sse", "--port=$MCP_GATEWAY_PORT", "--servers=$MCP_GATEWAY_SERVERS", "--verify-signatures"]
$proxy_env
    volumes:
      - $DOCKER_SOCK:/var/run/docker.sock
EOF
}

# ── mcpo: SSE-MCP → OpenAPI bridge so Open WebUI CHAT (not just the agents) gets the memory
# + gateway tools. Open WebUI consumes OpenAPI tool servers; cognee/graphiti and the gateway
# speak MCP-SSE, so mcpo translates. Active when chat is on and there's at least one MCP
# source — a self-hosted memory backend and/or the Docker MCP gateway.
owui_bridge_enabled() {
  [ "${ENABLE_OPENWEBUI:-false}" = "true" ] || return 1
  memory_self_host || mcp_gateway_enabled
}
# Active mcpo sub-server names — each is exposed at mcpo:8000/<name>/openapi.json.
mcpo_servers() {
  local s=""
  memory_self_host && s="memory"
  mcp_gateway_enabled && { [ -n "$s" ] && s="$s tools" || s="tools"; }
  printf '%s' "$s"
}
write_mcpo_config() {
  owui_bridge_enabled || return 0
  mkdir -p "$STACK_DIR/mcpo"
  local body="" first=1
  if memory_self_host; then
    body="    \"memory\": { \"type\": \"sse\", \"url\": \"$(memory_sse_url)\" }"; first=0
  fi
  if mcp_gateway_enabled; then
    [ "$first" = 0 ] && body="$body,"
    local gtok; gtok="$(secret_get mcp_gateway_token api_key_gen)"
    body="$body
    \"tools\": { \"type\": \"sse\", \"url\": \"$(mcp_gateway_sse_url)\", \"headers\": { \"Authorization\": \"Bearer $gtok\" } }"
  fi
  cat > "$STACK_DIR/mcpo/config.json" <<EOF
{
  "mcpServers": {
$body
  }
}
EOF
  chmod 600 "$STACK_DIR/mcpo/config.json" 2>/dev/null || true
}
append_mcpo_service() {
  owui_bridge_enabled || return 0
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  mcpo:
    image: $MCPO_IMAGE
    container_name: ${SAFE_STACK_NAME}-mcpo
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    command: ["--host", "0.0.0.0", "--port", "8000", "--config", "/app/config.json"]
    volumes:
      - ../mcpo/config.json:/app/config.json:ro
EOF
}
# Open WebUI TOOL_SERVER_CONNECTIONS JSON for the active mcpo sub-servers (chat tools).
owui_tool_server_connections() {
  owui_bridge_enabled || return 1
  local conns="" name first=1
  for name in $(mcpo_servers); do
    [ "$first" = 0 ] && conns="$conns,"
    conns="$conns{\"url\":\"http://mcpo:8000/$name\",\"path\":\"openapi.json\",\"auth_type\":\"none\",\"key\":\"\",\"config\":{\"enable\":true}}"
    first=0
  done
  printf '[%s]' "$conns"
}

# ───────────────────────────── LiteLLM gateway + Langfuse eval (first cut) ─────────────────────────────
llm_gateway_enabled() { [ "${LLM_GATEWAY:-false}" = "true" ]; }
eval_enabled()        { [ "${ENABLE_EVAL:-false}" = "true" ]; }

# LiteLLM config: a unified OpenAI endpoint (litellm:4000). Seeds the bundled Ollama model;
# add cloud models + keys under model_list. master_key gates the proxy.
write_litellm_config() {
  llm_gateway_enabled || return 0
  mkdir -p "$STACK_DIR/litellm"
  local key; key="$(secret_get litellm_master_key admin_pw_gen)"
  {
    printf 'model_list:\n'
    if ollama_enabled; then
      printf '  - model_name: %s\n    litellm_params:\n      model: openai/%s\n      api_base: http://ollama:11434/v1\n      api_key: os.environ/OLLAMA_API_KEY\n' "$OLLAMA_MODEL" "$OLLAMA_MODEL"
    fi
    printf '  # add cloud models, e.g.:\n  # - model_name: gpt-4o\n  #   litellm_params: { model: openai/gpt-4o, api_key: os.environ/OPENAI_API_KEY }\n'
    printf 'litellm_settings:\n  drop_params: true\n'
    printf 'general_settings:\n  master_key: "sk-%s"\n' "$key"
  } > "$STACK_DIR/litellm/config.yaml"
  chmod 600 "$STACK_DIR/litellm/config.yaml" 2>/dev/null || true
}
append_litellm_service() {
  llm_gateway_enabled || return 0
  local proxy_env=""
  egress_stack_enabled && stack_via_proxy && proxy_env="    environment:
$(stack_env_lines)"
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  litellm:
    image: $LITELLM_IMAGE
    container_name: ${SAFE_STACK_NAME}-litellm
    restart: unless-stopped
    env_file:
      - .runtime.env
    command: ["--config", "/app/config.yaml", "--port", "4000"]
$proxy_env
    volumes:
      - ../litellm/config.yaml:/app/config.yaml:ro
EOF
}

append_ollama_networks() {
  ollama_enabled || return 0
  cat >> "$(COMPOSE_FILE)" <<'EOF'

networks:
  ollama-private:
EOF
}

# Langfuse (v2 — single Postgres): LLM traces + evals + prompt management. UI on :3000
# (internal; reach it by port-forward / add a Caddy vhost — follow-up).
append_eval_service() {
  eval_enabled || return 0
  local dbpw na salt
  dbpw="$(secret_get langfuse_db_pw admin_pw_gen)"
  case "$dbpw" in
    ''|*[!A-Za-z0-9]*)
      dbpw="$(admin_pw_gen)"
      printf '%s' "$dbpw" | secret_set langfuse_db_pw ;;
  esac
  na="$(secret_get langfuse_nextauth)"; salt="$(secret_get langfuse_salt)"
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  langfuse-db:
    image: $LANGFUSE_DB_IMAGE
    container_name: ${SAFE_STACK_NAME}-langfuse-db
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    environment:
      - POSTGRES_USER=langfuse
      - POSTGRES_PASSWORD=$dbpw
      - POSTGRES_DB=langfuse
    volumes:
      - ../data/langfuse-db:/var/lib/postgresql/data

  langfuse:
    image: $LANGFUSE_IMAGE
    container_name: ${SAFE_STACK_NAME}-langfuse
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    environment:
      - DATABASE_URL=postgresql://langfuse:$dbpw@langfuse-db:5432/langfuse
      - NEXTAUTH_SECRET=$na
      - SALT=$salt
      - NEXTAUTH_URL=http://localhost:3000
      - TELEMETRY_ENABLED=false
$(stack_env_lines)
    depends_on: [langfuse-db]
EOF
}

# NOTE: embeddings run INSIDE Open WebUI (built-in sentence-transformers) — see
# compose_openwebui. That is cross-platform (arm64 + x86); a separate
# text-embeddings-inference container is x86-only, so it is intentionally not wired.
append_mcp_service() {
  mcp_enabled || return 0
  local embed_env=""
  [ -n "${EMBED_URL:-}" ] && embed_env="      - EMBED_URL=$EMBED_URL
      - EMBED_MODEL=${EMBED_MODEL:-$EMBEDDINGS_MODEL}"
  [ -n "${EMBED_API_KEY:-}" ] && embed_env="$embed_env
      - EMBED_API_KEY=$EMBED_API_KEY"
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  mcp:
    build: ../mcp
    image: ${SAFE_STACK_NAME}-mcp:1.0.0
    container_name: ${SAFE_STACK_NAME}-mcp
    restart: unless-stopped
    security_opt: [ "no-new-privileges:true" ]
    env_file:
      - .runtime.env
    environment:
      - QDRANT_URL=$QDRANT_URL
      - MCP_PORT=9000
$embed_env
    depends_on: [qdrant]
EOF
}

# The MCP stub source: a stdlib-only Python server (no pip install -> always builds
# offline). Serves /health and an SSE /sse placeholder, and can reach Qdrant via
# QDRANT_URL. Replace the TODO body in server.py with real MCP tools.
write_mcp_stub() {
  mkdir -p "$STACK_DIR/mcp"
  cat > "$STACK_DIR/mcp/Dockerfile" <<'EOF'
FROM python:3.12-alpine
WORKDIR /app
COPY server.py /app/server.py
EXPOSE 9000
CMD ["python", "/app/server.py"]
EOF
  cat > "$STACK_DIR/mcp/server.py" <<'EOF'
#!/usr/bin/env python3
"""psai MCP server — shared memory over Qdrant.

Tools (OpenAPI at /openapi.json for Open WebUI; mirrored over /sse for agents):
  POST /memory_store  {"text": str, "id"?: str}         -> upsert into Qdrant
  POST /memory_search {"query": str, "limit"?: int}     -> nearest stored texts

Dependency-free (urllib only). Embeddings are a hashing vectorizer (keyword-level),
so memory works out of the box; for SEMANTIC quality set EMBED_URL to an
OpenAI-compatible /embeddings endpoint (upgrade path) — same Qdrant either way.
"""
import os, json, math, uuid, hashlib, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

QDRANT_URL = os.environ.get("QDRANT_URL", "http://qdrant:6333")
PORT = int(os.environ.get("MCP_PORT", "9000"))
COLL = os.environ.get("MCP_COLLECTION", "psai_memory")
EMBED_URL = os.environ.get("EMBED_URL", "").rstrip("/")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "")
EMBED_KEY = os.environ.get("EMBED_API_KEY", "")
_HASH_DIM = 256


def _hash_embed(text):
    v = [0.0] * _HASH_DIM
    for tok in (text or "").lower().split():
        h = int(hashlib.md5(tok.encode()).hexdigest(), 16)
        v[h % _HASH_DIM] += 1.0
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def _remote_embed(text):
    body = json.dumps({"input": text or "", "model": EMBED_MODEL}).encode()
    headers = {"Content-Type": "application/json"}
    if EMBED_KEY:
        headers["Authorization"] = "Bearer " + EMBED_KEY
    req = urllib.request.Request(EMBED_URL + "/embeddings", data=body,
                                 method="POST", headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())["data"][0]["embedding"]


def embed(text):
    # External OpenAI-compatible embedder if EMBED_URL is set, else the hash encoder.
    if EMBED_URL:
        try:
            return _remote_embed(text)
        except Exception:
            return _hash_embed(text)
    return _hash_embed(text)


def _dim():
    if EMBED_URL:
        try:
            return len(_remote_embed("dimension probe"))
        except Exception:
            pass
    return _HASH_DIM


DIM = _dim()


def qreq(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(QDRANT_URL + path, data=data, method=method,
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=10) as resp:
        return json.loads(resp.read() or b"{}")


def ensure_collection():
    try:
        qreq("GET", "/collections/" + COLL)
    except Exception:
        qreq("PUT", "/collections/" + COLL, {"vectors": {"size": DIM, "distance": "Cosine"}})


def store(text, pid=None):
    ensure_collection()
    pid = pid or str(uuid.uuid4())
    qreq("PUT", "/collections/" + COLL + "/points",
         {"points": [{"id": pid, "vector": embed(text), "payload": {"text": text}}]})
    return {"id": pid, "stored": True}


def search(query, limit=5):
    ensure_collection()
    res = qreq("POST", "/collections/" + COLL + "/points/search",
               {"vector": embed(query), "limit": int(limit), "with_payload": True})
    return {"matches": [{"score": p.get("score"), "text": p.get("payload", {}).get("text")}
                        for p in res.get("result", [])]}


class Handler(BaseHTTPRequestHandler):
    OPENAPI = {
        "openapi": "3.1.0",
        "info": {"title": "psai MCP", "version": "1.0.0"},
        "paths": {
            "/memory_store": {"post": {
                "operationId": "memory_store", "summary": "Store text in shared memory (Qdrant)",
                "requestBody": {"required": True, "content": {"application/json": {"schema": {
                    "type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}}},
                "responses": {"200": {"description": "stored"}}}},
            "/memory_search": {"post": {
                "operationId": "memory_search", "summary": "Search shared memory (Qdrant)",
                "requestBody": {"required": True, "content": {"application/json": {"schema": {
                    "type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}}},
                "responses": {"200": {"description": "matches"}}}},
        },
    }

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok", "qdrant": QDRANT_URL, "collection": COLL})
        elif self.path in ("/openapi.json", "/openapi"):
            self._send(200, self.OPENAPI)
        elif self.path.startswith("/sse"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(b": psai mcp - tools: memory_store, memory_search\n\n")
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        except Exception:
            body = {}
        try:
            if self.path == "/memory_store":
                self._send(200, store(body.get("text", ""), body.get("id")))
            elif self.path == "/memory_search":
                self._send(200, search(body.get("query", ""), body.get("limit", 5)))
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:
            self._send(500, {"error": str(e)[:200]})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"psai mcp on :{PORT} qdrant={QDRANT_URL} coll={COLL}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
EOF
}

# ───────────────────────────── PentestGPT (opt-in, isolated) ─────────────────────────────
# AUTHORIZED security testing only. A container with PentestGPT installed; it runs idle
# and you `docker exec -it <stack>-pentest pentestgpt` to use it. LLM egress goes through
# proxy-stack; provide an LLM API key in the container's env/config.
write_pentest_dockerfile() {
  [ "$ENABLE_PENTEST" = "true" ] || return 0
  mkdir -p "$STACK_DIR/pentest"
  cat > "$STACK_DIR/pentest/Dockerfile" <<EOF
FROM $PENTEST_PY_IMAGE
RUN apt-get update && apt-get install -y --no-install-recommends git curl ca-certificates \\
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir pentestgpt \\
    || pip install --no-cache-dir "git+https://github.com/GreyDGL/PentestGPT.git"
WORKDIR /work
CMD ["sleep", "infinity"]
EOF
}

append_pentest_service() {
  [ "$ENABLE_PENTEST" = "true" ] || return 0
  cat >> "$STACK_DIR/compose/docker-compose.yml" <<EOF

  pentest:
    build: ../pentest
    image: ${SAFE_STACK_NAME}-pentest:1.0.0
    container_name: ${SAFE_STACK_NAME}-pentest
    restart: unless-stopped
    cap_drop: [ ALL ]
    security_opt: [ "no-new-privileges:true" ]
$(stack_env_lines)
    volumes:
      - ../data/pentest:/work
EOF
}

# True when the agents should get an MCP config.toml — a real memory MCP (cognee/graphiti
# or the stub) and/or the Docker MCP Gateway is active. Used BOTH to write the file and to
# mount it into OpenHands. Gating the mount on mcp_enabled alone silently dropped it for
# cognee/graphiti memory (where ENABLE_MCP=false), so the agents never got memory/tools.
openhands_mcp_config_active() {
  [ "${ENABLE_AGENTS:-false}" = "true" ] || return 1
  [ -n "$(memory_sse_url)" ] || [ -n "$(mcp_gateway_sse_url)" ]
}

# OpenHands reads [mcp].sse_servers from /app/config.toml.
write_openhands_mcp_config() {
  mkdir -p "$STACK_DIR/openhands-config"
  # Seed every active MCP source — the memory backend (stub mcp:9000 / cognee-graphiti
  # memory:8000 / mem0 cloud) AND the Docker MCP Gateway (tool servers) — so the agents get
  # shared memory + verified tools over the same config.
  local list="" u
  u="$(memory_sse_url)";      [ -n "$u" ] && list="\"$u\""
  # The gateway is token-gated: pass the pinned token as api_key so OpenHands sends
  # Authorization: Bearer … (a bare URL string would get 401).
  u="$(mcp_gateway_sse_url)"
  if [ -n "$u" ]; then
    [ -n "$list" ] && list="$list, "
    list="$list{url = \"$u\", api_key = \"$(secret_get mcp_gateway_token api_key_gen)\"}"
  fi
  if openhands_mcp_config_active && [ -n "$list" ]; then
    cat > "$STACK_DIR/openhands-config/config.toml" <<EOF
[mcp]
sse_servers = [$list]
EOF
  else
    rm -f "$STACK_DIR/openhands-config/config.toml" 2>/dev/null || true
  fi
}
