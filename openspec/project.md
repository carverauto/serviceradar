# Project Context

## Purpose
ServiceRadar is a distributed monitoring platform for infrastructure that lives in hard-to-reach or intermittently connected environments (README.md, docs/docs/intro.md). Agents installed alongside on-prem services stream health data to gateways; gateways feed the core-elx control plane via gRPC, and the SRQL + CNPG/Timescale analytics stack provides real-time insights even when sites experience outages. The product’s goal is to give operators one resilient control plane for discovery, alerting, and troubleshooting across SNMP/LLDP networks, OTEL telemetry, syslog feeds, and specialized device types such as Dusk network nodes.

## Tech Stack
- Elixir services (`elixir/serviceradar_core`, `elixir/serviceradar_agent_gateway`) handle control-plane APIs, gateway orchestration, and registration.
- Go services (`cmd/agent`, `cmd/sync`, `cmd/datasvc`, etc.) built with Bazel/Go modules power collectors, discovery, and sync integrations.
- Rust components (rule engine, collectors, flow/log agents) live under `rust/` and share bootstrap/config libraries for KV-backed hot reloads.
- Rust SRQL service (`rust/srql`) translates `/api/query` requests into CNPG queries using Diesel + pooled connections.
- Phoenix LiveView web UI (`web-ng/`) is served through an edge proxy (Caddy/Nginx/Ingress) and talks to the core API plus SRQL endpoints; legacy Next.js code remains in `web/` for reference only.
- CNPG/Timescale stores high-volume telemetry; SRQL and the core ingest layer both target Postgres hypertables (docs/docs/architecture.md).
- NATS JetStream backs the KV/datasvc configuration API that components use to watch and reload config (docs/docs/kv-configuration.md).
- SPIFFE/SPIRE handles workload identity and issues the mTLS credentials that every internal gRPC/HTTP hop relies on.
- Tooling: Docker Compose + Helm/Kubernetes for deployments, Make + Bazel for builds/tests, GitHub Actions CI, Discord for community + alert webhooks.

## Project Conventions

### Code Style
- Run `gofmt` (and `goimports`) on every Go file; keep packages organized under `pkg/` and prefer existing helpers before adding new dependencies.
- OCaml code is formatted with `dune fmt`; SRQL modules should follow existing naming (`Translator`, `Parser`, etc.).
- Rust crates use `cargo fmt`/`clippy`; collectors share bootstrap helpers from `rust/crates/config_bootstrap`.
- Web code is TypeScript-first with `npm run lint` (ESLint + Next rules) and Prettier formatting; keep UI strings ASCII.
- Docs in `docs/docs` are Markdown + Docusaurus frontmatter; keep ASCII-only and reference runbooks where possible.

### Architecture Patterns
ServiceRadar is layered (docs/docs/architecture.md):
- **User Edge**: Phoenix web UI → edge proxy (Caddy/Nginx/Ingress); the proxy terminates TLS and routes `/api/*` to web-ng.
- **Service Layer**: core-elx handles control-plane APIs and webhooks while Rust `srql` translates analytics queries and `datasvc` exposes KV over gRPC.
- **Monitoring Layer**: Stateless gateways fan out to gRPC agents deployed on monitored hosts; gateways orchestrate push/pull checks (HTTP, ICMP, SNMP, custom checkers).
- **Identity Plane**: SPIRE server/controller/workload agents mint SPIFFE identities used for every mutual-TLS hop.
- **Data Layer**: CNPG/Timescale hypertables capture raw events; SRQL and the registry build MV pipelines (device tables, planner, etc.).
Edge proxies terminate TLS and route traffic; watchers + KV descriptors keep service configs synchronized across demo and customer clusters (docs/docs/agents.md).

### Testing Strategy
- `make lint` / `make test` (or targeted `go test ./pkg/... ./cmd/...`) cover Go services; run `golangci-lint` locally when touching critical paths.
- Bazel: `bazel test --config=remote //...` or scoped targets for multi-language integration before release builds.
- SRQL: `cd rust/srql && cargo test` when editing the parser/planner.
- Rust: `cargo test` by crate; collectors also run `cargo clippy --all-targets`.
- Web UI: `cd web && npm install && npm run lint && npm run build` (CI mirrors this) plus component-level tests where present.
- End-to-end: use Docker Compose (`docker-compose up -d`) for smoke tests; demo cluster changes require k8s rollouts per docs/docs/agents.md.

### Git Workflow
- Specs-first: every net-new capability or behavioral change starts with an OpenSpec proposal under `openspec/changes/<change-id>/` (see openspec/AGENTS.md). Write proposal/tasks/delta specs, run `openspec validate <id> --strict`, and wait for approval before coding.
- Implementation happens on feature branches targeting `main`. Keep commits focused, reference the change-id, and update `tasks.md` checklists as items complete.
- Releases follow `scripts/cut-release.sh --version <semver>` which updates `VERSION` + `CHANGELOG`, tags the commit, and drives Bazel image builds before demo rollouts (README.md, Release Playbook).

## Domain Context
- Monitoring focus: SNMP/LLDP/CDP discovery, OTEL metrics, syslog ingestion, network mapper graph, Dusk node health, and specialized rule engines (README.md).
- Device pipeline: In demo, Armis faker → sync → core → CNPG maintains 50–70k canonical devices; runbook in docs/docs/agents.md covers pausing sync, truncating tables, recreating the MV, and verifying counts.
- KV-backed configuration: datasvc exposes KV gRPC endpoints that populate `/api/admin/config` descriptors; watchers mirror config into services and agent-scoped checkers follow the `agents/<id>/checkers/<service>/<service>.json` layout.
- Identity & security: SPIRE-issued certs + mTLS across agents/gateways/core/datasvc, core-issued JWTs for user/API traffic, API keys for internal automation, and webhook integrations for Discord/others (docs/docs/intro.md, docs/docs/architecture.md).
- Analytics: SRQL gives a key:value DSL that maps to CNPG SQL; device registry/search planner keep hot-path reads in memory while CNPG handles historical queries.

## Important Constraints
- Must operate across unreliable links; gateways continue orchestrating agents locally and buffer until core connectivity returns.
- All internal RPCs require mTLS with SPIFFE identities; KV, gateways, agents, and sync will refuse plaintext (docs/docs/kv-configuration.md, docs/docs/tls-security.md).
- Core is the policy enforcement point—JWT/JWKS must stay in sync with clients or the web UI cannot reach APIs.
- KV service expects co-located NATS JetStream and enforces RBAC per certificate DN; watchers rely on `CONFIG_SOURCE=kv` to auto-reload.
- CNPG datasets (device_updates/unified_devices) must stay pruned to keep queries fast and storage bounded; follow the reset procedure before reseeding demo data.
- Docker/Bazel outputs must target both AMD64 and ARM64; CI enforces multi-arch builds.

## External Dependencies
- **CNPG / TimescaleDB** – primary telemetry database and analytics engine.
- **NATS JetStream** – distributed KV backing datasvc and configuration watchers (docs/docs/kv-configuration.md).
- **Edge proxy (Caddy/Nginx/Ingress)** – terminates TLS and routes traffic to web-ng and core (docs/docs/architecture.md).
- **SPIFFE/SPIRE** – identity plane issuing certs for all workloads (docs/docs/spiffe-identity.md, docs/docs/spire-onboarding-plan.md).
- **Discord/Webhooks** – alert delivery target from the core service (README.md).
- **NetBox/Armis/edge tooling** – sync integrations and faker workloads supplying device data (docs/docs/agents.md, docs/docs/netbox.md).
- **Docker, Kubernetes, Helm, Bazel, Make, GitHub Actions** – build/test/deploy toolchain referenced throughout README.md and docs/docs/installation.md.
