# psai - Архитектура

<p align="center">
  <a href="ARCHITECTURE.md">English</a> | <b>Русский</b>
</p>


## Компоненты

| Сервис | Роль |
|---|---|
| `openwebui` | Чат - облачные + локальные модели, RAG поверх Qdrant, веб-поиск через SearXNG |
| `openhands` | ИИ-агенты (OpenHands) - автономный код/автоматизация; запускает sandbox-контейнеры (по умолчанию через Docker-сокет хоста - см. Безопасность) |
| `searxng` | Приватный метапоиск, подключён к чату и агентам (JSON API) |
| `forgejo` | Self-hosted git |
| `qdrant` | Общая векторная память для чата и агентов |
| `embed` | RAG-plus на Linux x64: локальные эмбеддинги + reranker (Infinity, OpenAI-compatible); macOS/Linux ARM по умолчанию используют Ollama embeddings |
| `ingest-docling` / `ingest-tika` | RAG-plus: чтение документов - Docling (таблицы/формулы/OCR -> Markdown) с Apache Tika как fallback |
| `mcp` | Общий MCP-сервер - `memory_store` / `memory_search` поверх Qdrant |
| `memory` | Реальная общая память - Cognee graph+vector или Graphiti temporal graph, доступная через MCP-SSE |
| `ollama` | Встроенный локальный OpenAI-compatible LLM endpoint для чата и памяти |
| `mcp-gateway` | Authenticated Docker MCP Gateway - verified, signature-checked allowlist tool-серверов |
| `mcpo` | SSE-MCP -> OpenAPI bridge - память и gateway tools внутри чата Open WebUI |
| `litellm` | LiteLLM model gateway - один OpenAI endpoint для routing/fallback/cache/budgets |
| `langfuse` | LLM traces, evals и prompt management |
| `pentest` | PentestGPT - опционально, изолированно, только авторизованное тестирование |
| `caddy` | Реверс-прокси + TLS (local CA / ACME / свой cert / self-signed) |
| `proxy-stack` | Egress firewall - весь model API traffic (cloud + local) и обновления компонентов |
| `proxy-web` | Egress firewall - поиск и браузинг агентов (web worker) |
| `stack-vault` | Секреты в secret-памяти (`memfd_secret` на Linux 5.14+, `mlock` fallback) - локальный **stack-vault** на single node; **KMS vault** в multi node (на мастере или отдельной KMS-ноде) |

## Single node

![psai - топология одного узла](img/single-node.png)

Один хост. Слой секретов - локальный **stack-vault**: секреты в secret-памяти (`memfd_secret` на Linux 5.14+, `mlock` fallback), ручной пароль. Open WebUI и OpenHands делят один слой tools и memory: memory backend говорит по MCP-SSE, Docker MCP Gateway даёт verified tools с Bearer-токеном из vault, а `mcpo` превращает эти MCP-источники в OpenAPI tool servers для чата Open WebUI. Open WebUI также индексирует свои RAG-документы прямо в Qdrant. В интернет всё выходит только через egress-прокси.

**RAG-plus (`PSAI_RAG=plus`)** усиливает retrieval platform-aware эмбеддингами. Linux x64 по умолчанию использует сервис `embed` (Infinity, OpenAI-compatible) плюс CrossEncoder reranker; macOS и Linux ARM по умолчанию используют встроенные Ollama embeddings (`nomic-embed-text`), чтобы не упираться в медленную или недоступную amd64-эмуляцию. Слой `ingest` (Docling -> Markdown/JSON, Apache Tika fallback) парсит PDF/DOCX/таблицы/формулы перед chunking. Поток на Linux x64: *document -> Docling/Tika -> chunk -> embed (Infinity) -> Qdrant -> recall -> rerank -> answer.* Поток на macOS/Linux ARM: *document -> Docling/Tika -> chunk -> Ollama embeddings -> Qdrant -> recall -> answer.* Hybrid dense+BM25 включается отдельно (`PSAI_RAG_HYBRID`). *(PNG-топология для этого потока ещё будет нарисована.)* PentestGPT не имеет web UI (в него заходят через `docker exec`), но его трафик идёт через прокси, как и всё остальное. Блок на схеме - это один хост; отдельного "master" в single-node нет, эта роль появляется только в multi-node схеме ниже.

Порты: Open WebUI `:8080`, OpenHands `:3000`, SearXNG `:8080`, Forgejo `:3000` (плюс SSH на выбранном порту), Qdrant `:6333`, MCP `:9000`. На host ports публикуется только Caddy (`80`/`443`). Остальное остаётся во внутренней Docker-сети, а всё опубликованное проходит через Caddy с опциональным basic-auth.

**Домены на локальной установке опциональны.** Проходишь шаг доменов - получаешь `.lan` vhosts через local CA (HTTPS). Пропускаешь (`PSAI_NO_DOMAIN=true`) - Caddy публикует каждый сервис на отдельном loopback-порту: Open WebUI `:8080`, OpenHands `:8081`, Forgejo `:8082`, Qdrant `:8083`; без правки `/etc/hosts` и без доверия сертификату. Публичная установка всегда использует реальный домен или IP хоста с self-signed сертификатом.

## Multi-node - master | KMS | agent worker nodes

![psai - multi-node топология (master node | KMS node | agent worker nodes)](img/architecture.png)

`master_node_0` - control plane. Он запускает стек и управляет каждым `agent_worker_<N>` через SSH-туннель только внутри WireGuard, забирая их данные домой. Адресация фиксированная: master - WG `.1`, `agent_worker_<N>` - WG `.{2+N}`, опциональная KMS-нода - `.254`. Agent worker node самодостаточна: свои OpenHands, SearXNG и `proxy-web`; доступна только внутри WireGuard. Web-доступ включается отдельно. Один Qdrant на мастере общий для агентов через туннель, поэтому чат и каждый агент читают одну память. Сейчас state collection забирает данные и workspaces домой; per-node health/log snapshots ещё в roadmap.

`psai agents --host IP` provisioning-ит агента. Он ставит Docker и OpenHands stack, строит WireGuard-туннель, harden-ит хост (CIS sysctls, ufw), и на strict-профиле переводит публичный SSH в WireGuard-only с reboot failback window, чтобы консольный reboot всегда временно открывал SSH обратно.

**KMS vault.** В multi-node слой секретов - это KMS vault: хранилище ключей и KMS-сервер, который unseal-ит каждого агента поверх WireGuard. Он работает на мастере или на отдельной ноде (`psai kms-node --host IP`). Каждый agent worker node тоже запускает `stack-vault`, но KMS vault unseal-ит его по туннелю вместо локального пароля. Во время `agents --host` KMS vault генерирует unseal key агента и auth token. `vault.enc` агента шифруется этим ключом, а на агента отправляется только token (в `kms.conf`) - сам ключ никогда не попадает на диск агента. При каждом старте агент забирает ключ из KMS vault (`stack-vault kms` отдаёт `agent_unseal_<id>`, gated by `kms_token_<id>`) по WireGuard. Без пароля; если KMS или туннель недоступны, агент остаётся sealed.

**Привязка к hardware fingerprint.** Один token не останавливает clone диска. Если скопировать диск агента - token и WireGuard key - на другой VPS, то при живом туннеле он тоже мог бы попросить ключ. Поэтому KMS vault дополнительно привязывает каждого агента к hardware fingerprint. При provisioning он читает fingerprint агента (`stack-vault fingerprint`) и сохраняет его как `agent_fp_<id>`. Fingerprint - SHA-256 по ID, которых нет в raw disk image: прежде всего SMBIOS/DMI **product UUID**, который hypervisor выдаёт каждой VM, плюс `machine-id` и CPU model. Каждый unseal request несёт `GET <id> <token> <fp>`, и KMS отказывает (`ERR denied-hwid`), если fingerprint не совпадает. Clone, запущенный на другом железе, получает другой UUID, другой fingerprint и получает отказ. Ограничение: сильная привязка требует, чтобы vault агента мог прочитать `product_uuid`, а он root-only; без этого fallback - `machine-id`, который привязывает к OS install, а не к железу. Реальная смена железа (VPS migration) тоже меняет fingerprint и требует re-register.

Что это даёт и чего не даёт: custody ключей находится в KMS vault, который может быть offline и позже может revoke/rotate ключи, а fingerprint останавливает простой clone диска на другом железе. Это не останавливает того, кто уже выполняет код на live agent - host-root там всё равно читает unsealed RAM. KMS vault на отдельной ноде реализован как first cut (он peer-ится во fleet WireGuard на `.254`, hub-and-spoke через master); live-тест на трёх хостах ещё pending. KMS и fingerprint protocol протестированы end-to-end.

## Egress proxies - firewall + router

Два шлюза. Каждый - router и firewall. Router выбирает next hop: direct, Tor или VPN/tunnel client. Firewall - единственный разрешённый выход, с DNS pinning, kill-switch и опциональным allow-list. Оба по умолчанию direct, и любой можно перенастроить из dashboard на лету.

![psai - egress proxies (firewall + router): proxy-stack and proxy-web](img/egress.png)

- **`proxy-stack`** - каждый model API call от приложений (cloud и local), плюс component downloads и updates. Local models остаются direct (в `NO_PROXY`), если не задан `PSAI_ROUTE_LOCAL_LLM=true`; большие Ollama model pulls тоже direct по умолчанию, но их можно принудительно пустить через proxy с `PSAI_OLLAMA_PULL_VIA_PROXY=true`.
- **`proxy-web`** - search queries и browsing sandbox-а OpenHands. В multi-node он также работает на каждой agent worker node.

Приложения ходят к proxy по service name. Tor и VLESS поднимают HTTP listener на `:8118`. Tunnel modes (`wireguard` / `adguardvpn` / `tailscale`) запускают tinyproxy sidecar на `:8888`, который делит network namespace tunnel-контейнера, поэтому sidecar может выйти наружу только через tunnel. `proxy-web` также публикуется на loopback хоста, чтобы OpenHands sandbox (отдельная сеть) мог дотянуться до него через `host.docker.internal`.

В WireGuard config превращается в firewall. DNS закреплён за одним resolver (`PSAI_PROXY_DNS`). Kill-switch (`PSAI_PROXY_KILLSWITCH`) добавляет `iptables` rule, который reject-ит любой egress не через tunnel - упавший tunnel означает остановку трафика, а не leak. `PSAI_PROXY_ALLOW_CIDR` ограничивает destinations, а `PSAI_PROXY_ALLOW_FQDN` резолвит домены в `/32` entries на этапе config. Tor и VLESS изолируют egress по построению.

## Безопасность

Три профиля. Каждый пункт переключается отдельно после установки (dashboard -> security). Переключение профиля просто заново применяет defaults ниже.

| Capability | Strict | Default | None |
|---|:--:|:--:|:--:|
| Container hardening (`no-new-privileges`, `cap_drop`) | да | да | да |
| Secrets in `stack-vault` (secret memory, manual passphrase) | да | - | - |
| TPM auto-unseal (hardware-bound, Linux; toggle в security setup) | опц | - | - |
| Secrets in plaintext `.env` (disk) | - | да | да |
| CIS sysctls + sshd + auto-upgrades | да | да | - |
| Host firewall | да | - | - |
| Watchdog | да | - | - |
| Disable public SSH (WireGuard-only, multi-node) | да | - | - |
| fail2ban (public) | да | - | - |

Anti-lockout встроен в дизайн: firewall разрешает текущий SSH port до любого deny, а public SSH отключается только после подтверждения, что SSH-over-WireGuard работает.

**OpenHands и Docker socket.** OpenHands - agent runtime, который запускает свои sandbox-контейнеры. По умолчанию (`PSAI_OH_MODE=host`) он делает это через Docker socket хоста, что фактически даёт контроль уровня хоста - это не сильная песочница. `PSAI_OH_MODE=dind` запускает вложенный Docker daemon, чтобы socket хоста не шарился; на shared/untrusted host лучше использовать его. `AGENTS_DOCKER=true` также монтирует host Docker socket внутрь agent sandbox; installer предупреждает на public deployments, но разрешает явный override. Stateless services (Open WebUI / SearXNG / Caddy) остаются locked down (`no-new-privileges`, `cap_drop ALL`); OpenHands так не может, потому что управляет контейнерами. Компонент agents опционален (`PSAI_AGENTS=false`).

### Секреты - `stack-vault`

Два базовых режима:

1. **Default - plaintext `.env`.** Секреты лежат в config files на диске и защищены только disk encryption хоста. Нормально для машины, которой ты доверяешь.
2. **Vault - `stack-vault` (strict).** Небольшой Rust-демон является secret store. Каждый секрет живёт только в secret-памяти демона. Потребители забирают их через Unix socket с peer-credentials gate (`SO_PEERCRED` / `getpeereid`, только same uid), core dumps выключены. На диске только AES-256-GCM blob, ключ от пароля через Argon2id. Пароль вводится при каждом старте и никогда не хранится, поэтому reboot теряет in-RAM key и vault остаётся sealed до повторного ввода. На одном хосте это локальный `stack-vault`; в multi-node тот же daemon работает как KMS vault, который unseal-ит agents.

На Linux 5.14+ каждый секрет держится в `memfd_secret` region - pages удалены из kernel direct map, поэтому `/dev/mem`, `/proc/kcore`, swap и `ptrace` / `process_vm_readv` (через `get_user_pages`) не могут их прочитать даже root. Без secretmem (старое ядро, macOS) fallback - `mlock` RAM (без swap, без core dump). `stack-vault status` показывает реальный backing: `mem=secretmem`, `mem=mlock` или `mem=unlocked`, если даже lock не сработал (например, слишком низкий `RLIMIT_MEMLOCK` в контейнере), поэтому статус не заявляет защиту, которой нет. Демон также запускается non-dumpable (`PR_SET_DUMPABLE 0`).

![stack-vault | memfd_secret - секреты в region, который kernel не мапит никому, даже root (fallback: mlock RAM)](img/kms.png)

Опционально поверх vault: **TPM auto-unseal** (`PSAI_VAULT_TPM`, или toggle в security setup). На Linux с `tpm2-tools` он запечатывает пароль в TPM машины, чтобы vault unseal-ился на этом железе без prompt. Sealed blob бесполезен на другой машине. Выключаешь - seal удаляется, возвращаешься к ручному вводу пароля.

Runtime secrets, которые нужны контейнерам (session keys), рендерятся из vault в `.runtime.env` и shredded на stop. На Linux этот файл backed by tmpfs (`/dev/shm`), поэтому не касается диска. SearXNG использует placeholder plus env substitution. Sealed stack оставляет на диске только encrypted blob. Vault может rotate passphrase in place (`stack-vault reseal`); `psai rekey <idx>` использует это для rotation agent key.

Что это даёт: сокращает окно, где секреты plaintext, и блокирует unprivileged reads. С `memfd_secret` (Linux 5.14+) даже host-root не может прочитать секреты из live process; на `mlock` fallback root всё ещё может (и в любом случае мог бы ptrace-inject код в process - используй Yama `ptrace_scope`). Оставшиеся hardware-bound paths доделываются поэтапно: KMS vault на отдельной ноде, TPM auto-unseal и будущий Secure Enclave sealing.

## Dashboard

Запусти `psai` без аргументов - откроется operator dashboard. Он показывает active version, channel, profile, stack name, node role, domain и live component table с колонками image, state и health. Рабочие действия сгруппированы в Run, Data, Network и Settings: start/stop/logs, setup/removal компонентов, переключение security profile, настройка proxy, update, backup, а в multi-node режиме - операции с agent worker nodes (`fleet`, `rekey`, `state`). Profile changes остаются внутри текущего deployment: local stack остаётся local, public stack остаётся public.

## Карта модулей (`lib/*.sh`)

```text
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
