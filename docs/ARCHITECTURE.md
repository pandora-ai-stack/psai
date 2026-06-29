# psai - Architecture

<p align="center">
  <b>English</b> | <a href="ARCHITECTURE.ru.md">Русский</a>
</p>

`v1.0.0 beta`. `psai.sh` is one bash script, assembled from `lib/*.sh` by `build.sh`. Secrets are handled by a small Rust daemon, **stack-vault** (`vault/`).

## Components

| Service | Role |
|---|---|
| `openwebui` | Chat UI - cloud + local models, RAG over Qdrant, web search via SearXNG |
| `openhands` | AI agents (OpenHands) - autonomous coding/automation; spawns sandbox containers (default: host Docker socket - see Security) |
| `searxng` | Private metasearch, wired into chat and the agents (JSON API) |
| `forgejo` | Self-hosted git |
| `qdrant` | Shared vector memory for chat + agents |
| `embed` | RAG-plus on Linux x64: local embeddings + reranker (Infinity, OpenAI-compatible); macOS/Linux ARM use Ollama embeddings by default |
| `ingest-docling` / `ingest-tika` | RAG-plus: document ingest - Docling (tables/formulas/OCR -> Markdown) with Apache Tika fallback |
| `mcp` | Shared MCP server - `memory_store` / `memory_search` over Qdrant |
| `memory` | Real shared memory - Cognee graph+vector or Graphiti temporal graph, exposed over MCP-SSE |
| `ollama` | Bundled local OpenAI-compatible LLM endpoint for chat and memory |
| `mcp-gateway` | Authenticated Docker MCP Gateway - verified, signature-checked tool-server allowlist |
| `mcpo` | SSE-MCP -> OpenAPI bridge - memory and gateway tools inside Open WebUI chat |
| `litellm` | LiteLLM model gateway - one OpenAI endpoint for routing/fallback/cache/budgets |
| `langfuse` | LLM traces, evals, and prompt management |
| `pentest` | PentestGPT - opt-in, isolated, authorized testing only |
| `caddy` | Reverse proxy + TLS (local CA / ACME / own cert / self-signed) |
| `proxy-stack` | Egress firewall - all model API traffic (cloud + local) and component updates |
| `proxy-web` | Egress firewall - search and agent browsing (the web worker) |
| `stack-vault` | Secrets in secret memory (`memfd_secret` on Linux 5.14+, `mlock` fallback) - local **stack-vault** on single node; **KMS vault** on multi node (on the master or a separate KMS node) |

## Single node

![psai - single-node topology](img/single-node.png)

One host. The secrets layer is the local **stack-vault** - secrets in secret memory (`memfd_secret` on Linux 5.14+, `mlock` fallback), manual passphrase. Open WebUI and OpenHands share one tool and memory layer: the memory backend speaks MCP-SSE, Docker MCP Gateway provides verified tools with a vault-pinned Bearer token, and `mcpo` bridges those MCP sources into OpenAPI tool servers for Open WebUI chat. Open WebUI also indexes its RAG documents straight into Qdrant. Both reach the internet only through the egress proxies.

**RAG-plus (`PSAI_RAG=plus`)** sharpens retrieval with platform-aware embeddings. Linux x64 defaults to the `embed` service (Infinity, OpenAI-compatible) plus a CrossEncoder reranker; macOS and Linux ARM default to bundled Ollama embeddings (`nomic-embed-text`) to avoid slow or unavailable amd64 emulation paths. The `ingest` layer (Docling -> Markdown/JSON, Apache Tika fallback) parses PDF/DOCX/tables/formulas before chunking. Flow on Linux x64: *document -> Docling/Tika -> chunk -> embed (Infinity) -> Qdrant -> recall -> rerank -> answer.* Flow on macOS/Linux ARM: *document -> Docling/Tika -> chunk -> Ollama embeddings -> Qdrant -> recall -> answer.* Hybrid dense+BM25 is opt-in (`PSAI_RAG_HYBRID`). *(A topology PNG for this flow is still to be drawn.)* PentestGPT has no web UI (you `docker exec` into it), but its traffic goes through the proxies like everything else. (The diagram's node block is that single host - there is no separate "master" in single-node; that role only exists in the multi-node layout below.)

Ports: Open WebUI `:8080`, OpenHands `:3000`, SearXNG `:8080`, Forgejo `:3000` (plus SSH on the port you pick), Qdrant `:6333`, MCP `:9000`. Only Caddy publishes host ports (`80`/`443`). Everything else stays on the internal Docker network, and where it's exposed it sits behind Caddy with optional basic-auth.

**Domains are optional on a local install.** Take the domain step and you get `.lan` vhosts over the local CA (HTTPS). Skip it (`PSAI_NO_DOMAIN=true`) and Caddy publishes each service on its own loopback port - Open WebUI `:8080`, OpenHands `:8081`, Forgejo `:8082`, Qdrant `:8083` - no `/etc/hosts` edits, no cert to trust. A public install always uses a real domain, or the host IP with a self-signed cert.

## Multi-node - master | KMS | agent worker nodes

![psai - multi-node topology (master node | KMS node | agent worker nodes)](img/architecture.png)

`master_node_0` is the control plane. It runs the stack and manages each `agent_worker_<N>` over a WireGuard-only SSH tunnel, pulling their data home. Addressing is fixed: the master is WG `.1`, `agent_worker_<N>` is WG `.{2+N}`, an optional KMS node is `.254`. An agent worker node is self-contained - its own OpenHands, SearXNG, and `proxy-web` - and reachable only inside WireGuard. Web access is opt-in. One Qdrant on the master is shared with the agents over the tunnel, so chat and every agent read the same memory. State collection today pulls data and workspaces home; per-node health/log snapshots are still on the roadmap.

`psai agents --host IP` provisions an agent. It installs Docker and an OpenHands stack, builds the WireGuard tunnel, hardens the host (CIS sysctls, ufw), and - on the strict profile - drops public SSH to WireGuard-only with a reboot failback window, so a console reboot always reopens an SSH window.

**The KMS vault.** In multi-node the secrets layer is a KMS vault: the keys store and KMS server that unseals every agent over WireGuard. It runs on the master, or on its own node (`psai kms-node --host IP`). Each agent worker node runs `stack-vault` too, but the KMS vault unseals it over the tunnel instead of a local passphrase. During `agents --host` the KMS vault generates the agent's unseal key and an auth token. The agent's `vault.enc` is encrypted with that key, and only the token is pushed to the agent (in `kms.conf`) - the key never lands on the agent's disk. On every start the agent fetches its key from the KMS vault (`stack-vault kms` serves `agent_unseal_<id>`, gated by `kms_token_<id>`) over WireGuard. No passphrase, and it stays sealed if the KMS or the tunnel is down.

**Hardware-fingerprint binding.** The token alone doesn't stop a disk clone. Copy the agent's disk - token and WireGuard key - onto another VPS, and while the tunnel is up it could ask for the key. So the KMS vault also binds each agent to a hardware fingerprint. At provisioning it reads the agent's fingerprint (`stack-vault fingerprint`) and stores it as `agent_fp_<id>`. The fingerprint is a SHA-256 over IDs a raw disk image doesn't carry - mainly the SMBIOS/DMI **product UUID**, which the hypervisor assigns per VM, plus `machine-id` and the CPU model. Every unseal request carries `GET <id> <token> <fp>`, and the KMS refuses it (`ERR denied-hwid`) unless the fingerprint matches. A clone booted on different hardware gets a different UUID, a different fingerprint, and is denied. Caveat: strong binding needs the agent's vault to read `product_uuid`, which is root-only; without that it falls back to `machine-id`, which binds to the OS install, not the hardware. A real hardware change (VPS migration) also changes the fingerprint and means re-registering.

What this does and doesn't do: key custody sits in the KMS vault, which can be offline and can later revoke or rotate keys, and the fingerprint stops a plain disk clone on other hardware. It does not stop someone running code on the live agent - host-root there reads the unsealed RAM either way. Running the KMS vault on its own node is implemented as a first cut (it peers into the fleet WireGuard at `.254`, hub-and-spoke through the master); a three-host live test is still pending. The KMS and fingerprint protocol is tested end-to-end.

## Egress proxies - firewall + router

Two gateways. Each one is a router and a firewall. The router picks the next hop: direct, Tor, or a VPN/tunnel client. The firewall is the only sanctioned exit, with DNS pinning, a kill-switch, and an optional allow-list. Both default to direct, and you can reconfigure either from the dashboard while it runs.

![psai - egress proxies (firewall + router): proxy-stack and proxy-web](img/egress.png)

- **`proxy-stack`** - every model API call the apps make (cloud and local), plus component downloads and updates. Local models stay direct (in `NO_PROXY`) unless `PSAI_ROUTE_LOCAL_LLM=true`; large Ollama model pulls also stay direct by default and can be forced through the proxy with `PSAI_OLLAMA_PULL_VIA_PROXY=true`.
- **`proxy-web`** - search queries and the OpenHands sandbox's browsing. In multi-node it also runs on each agent worker node.

The apps reach the proxies by service name. Tor and VLESS run an HTTP listener on `:8118`. The tunnel modes (`wireguard` / `adguardvpn` / `tailscale`) run a tinyproxy sidecar on `:8888` that shares the tunnel container's network namespace, so the sidecar can only get out through the tunnel. `proxy-web` is also published on host loopback, so the OpenHands sandbox (a separate network) can reach it via `host.docker.internal`.

On WireGuard the config becomes a firewall. DNS is pinned to one resolver (`PSAI_PROXY_DNS`). A kill-switch (`PSAI_PROXY_KILLSWITCH`) adds an `iptables` rule that rejects any egress not leaving through the tunnel - a dropped tunnel means no traffic, not a leak. `PSAI_PROXY_ALLOW_CIDR` limits destinations, and `PSAI_PROXY_ALLOW_FQDN` resolves domains to `/32` entries at config time. Tor and VLESS confine egress by design.

## Security

Three profiles. Every capability toggles on its own after install (dashboard -> security). Switching profiles just re-applies the defaults below.

| Capability | Strict | Default | None |
|---|:--:|:--:|:--:|
| Container hardening (`no-new-privileges`, `cap_drop`) | yes | yes | yes |
| Secrets in `stack-vault` (secret memory, manual passphrase) | yes | - | - |
| TPM auto-unseal (hardware-bound, Linux; toggle in security setup) | opt | - | - |
| Secrets in plaintext `.env` (disk) | - | yes | yes |
| CIS sysctls + sshd + auto-upgrades | yes | yes | - |
| Host firewall | yes | - | - |
| Watchdog | yes | - | - |
| Disable public SSH (WireGuard-only, multi-node) | yes | - | - |
| fail2ban (public) | yes | - | - |

Anti-lockout is built into the design: the firewall allows the live SSH port before it denies anything, and public SSH drops only after SSH-over-WireGuard is confirmed working.

**OpenHands & the Docker socket.** OpenHands is an agent runtime that spawns its own sandbox containers. By default (`PSAI_OH_MODE=host`) it does that through the host's Docker socket, which is effectively host-level control - not a strong sandbox. `PSAI_OH_MODE=dind` runs a nested Docker daemon so the host socket isn't shared; prefer it on a shared or untrusted host. `AGENTS_DOCKER=true` also mounts the host Docker socket into the agent sandbox; the installer warns on public deployments but allows the explicit override. The stateless services (Open WebUI / SearXNG / Caddy) stay locked down (`no-new-privileges`, `cap_drop ALL`); OpenHands can't, because it manages containers. The agents component is optional (`PSAI_AGENTS=false`).

### Secrets - `stack-vault`

Two base modes:

1. **Default - plaintext `.env`.** Secrets sit in config files on disk, protected only by the host's disk encryption. Fine on a machine you trust.
2. **Vault - `stack-vault` (strict).** A small Rust daemon is the secret store. Every secret lives only in the daemon's secret memory. Consumers fetch them over a Unix socket gated by peer credentials (`SO_PEERCRED` / `getpeereid`, same uid only), and core dumps are off. The only thing on disk is an AES-256-GCM blob, keyed from a passphrase via Argon2id. The passphrase is entered on every start and never stored, so a reboot loses the in-RAM key and the vault stays sealed until you enter it again. On one host this is the local `stack-vault`; in multi-node the same daemon runs as the KMS vault that unseals the agents.

On Linux 5.14+ each secret is held in a `memfd_secret` region - pages removed from the kernel's direct map, so `/dev/mem`, `/proc/kcore`, swap, and `ptrace` / `process_vm_readv` (via `get_user_pages`) can't read them, even as root. Without secretmem (older kernel, macOS) it falls back to `mlock`'d RAM (no swap, no core dump). `stack-vault status` reports the real backing - `mem=secretmem`, `mem=mlock`, or `mem=unlocked` if even the lock didn't take (e.g. a too-low `RLIMIT_MEMLOCK` in a container), so the status never claims protection it doesn't have. The daemon also runs non-dumpable (`PR_SET_DUMPABLE 0`).

![stack-vault | memfd_secret - secrets in a region the kernel won't map for anyone, even root (fallback: mlock'd RAM)](img/kms.png)

Optional on top of the vault: **TPM auto-unseal** (`PSAI_VAULT_TPM`, or the toggle in the security setup). On Linux with `tpm2-tools` it seals the passphrase to the machine's TPM, so the vault unseals on that hardware without a prompt. The sealed blob is useless on any other machine. Turn it off and the seal is dropped - you're back to entering the passphrase.

Runtime secrets the containers need (session keys) are rendered from the vault into a `.runtime.env` and shredded on stop. On Linux that file is backed by tmpfs (`/dev/shm`), so it never touches the disk. SearXNG uses a placeholder plus env substitution. A sealed stack leaves nothing on disk but the encrypted blob. The vault can rotate its passphrase in place (`stack-vault reseal`); `psai rekey <idx>` uses that to rotate an agent's key.

What this buys you: it shrinks the window where secrets are in plaintext and blocks unprivileged reads. With `memfd_secret` (Linux 5.14+) even host-root can't read the secrets from the live process; on the `mlock` fallback, root still can (and could ptrace-inject code into the process regardless - pair with Yama `ptrace_scope`). The remaining hardware-bound paths are being completed incrementally: the KMS vault on its own node, TPM auto-unseal, and future Secure Enclave sealing.

## Dashboard

Run `psai` with no argument to open the operator dashboard. It shows the active version, channel, profile, stack name, node role, domain, and a live component table with image, state, and health columns. The dashboard groups routine work into Run, Data, Network, and Settings: start/stop/logs, component setup and removal, security profile changes, proxy configuration, update, backup, and - in multi-node mode - agent worker operations (`fleet`, `rekey`, `state`). Profile changes stay inside the current deployment; a local stack stays local, and a public stack stays public.

## Module map (`lib/*.sh`)

```
00-header    globals | names | images | component + proxy + profile vars
05-banner    installer + dashboard banners + context line
10-i18n      colours/tty | t() EN/RU
20-helpers   ask/confirm/prompt | aligned menus | step spinner
30-ui        headers | runtime metrics | language
40-system    sudo/admin | docker socket | colima | compose()
50-domains   zones | service domains | inline editor | no-domain ports
55-deps      environment checks + dependency setup
60-config    .stack.env | secrets | directories
70-profile   strict/default/none | preview | per-toggle tuning (incl. TPM)
72-hardening firewall | CIS | sshd
74-watchdog  health watchdog
76-seal      legacy openssl seal (fallback only)
77-vault     stack-vault - build | unseal | seal | reseal | get/put | KMS | TPM
80-egress    proxy-stack + proxy-web | WireGuard firewall | FQDN allow-list
81-hosts     /etc/hosts + local-CA trust + A-record check
82-caddy     Caddyfile + TLS (local CA / ACME / own / self-signed)
84-compose   docker-compose.yml generator + write_all_configs
85-mcp       qdrant | embed/Ollama embeddings | ingest | memory | MCP gateway | mcpo | LiteLLM | Langfuse | PentestGPT
86-multinode master/agent over WireGuard | KMS | kms-node | rekey | state
88-install   install flow (single + multi)
90-lifecycle start/stop/uninstall/update/rebuild
92-dashboard operator dashboard + management menus
94-backup    encrypted 7z backup/restore
96-cron      docker auto-update | signed self-update | checks
99-main      CLI dispatch + entry
```
