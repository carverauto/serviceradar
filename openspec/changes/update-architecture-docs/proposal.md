# Change: Documentation Overhaul for Current (Elixir + Wasm-Agent) Architecture

## Why
The current documentation set mixes multiple generations of ServiceRadar architecture (legacy Go control plane + legacy UI + KV/datasvc-driven configuration + standalone checkers) with today’s reality:

- The control plane is Elixir on ERTS with clustering (core-elx, web-ng, agent-gateway).
- The edge agent is a single Go binary with an embedded `wazero` Wasm runtime executing sandboxed plugins.
- Previously standalone components (sync integrations, SNMP poller, mapper/discovery, Dusk checker) have moved into the agent (or run as Wasm plugins inside the agent).
- The agent connects to agent-gateway via mTLS gRPC using streaming (including chunked payloads) and a bidirectional command bus.
- agent-gateway forwards into the control plane over ERTS/RPC/PubSub (not “gateway gRPC to core”).
- NATS JetStream remains as the bulk ingestion backbone for collectors; “config via nats-kv” is removed.
- SPIFFE/SPIRE is Kubernetes-only; Docker Compose uses non-SPIFFE mTLS bootstrapping.

Keeping outdated docs around creates the wrong mental model and slows onboarding. This change replaces the docs IA and architecture content with concise, accurate documentation for the current platform, without any “legacy transition” narrative.

## What Changes
### Information Architecture (Docs Site)
- Replace the current wide sidebar with a smaller set of functional sections:
  - Introduction
  - Quickstart
  - Architecture
  - Deployment (Docker Compose, Kubernetes/Helm)
  - Edge (agent lifecycle, config, command bus, plugins)
  - Data pipeline (NATS JetStream collectors, consumers, CNPG)
  - Troubleshooting + Runbooks
- Consolidate or remove low-value/legacy pages so navigation stays short and task-oriented.

### Audit Findings (Concrete Issues To Remove)
The following are examples of the current “wrong mental model” content that this change removes (rewrite or delete, depending on whether the topic is still relevant):

- KV/datasvc guidance for rules and secrets (for example: `docs/docs/cluster.md`, `docs/docs/syslog.md`, `docs/docs/snmp.md`, `docs/docs/rule-builder.md`, `docs/docs/srql-service.md`, `docs/docs/agents.md`).
- Docker Compose docs that treat SPIFFE/SPIRE as part of the Compose story (SPIFFE is Kubernetes-only).
- Architecture docs that describe “gateway forwards to core over gRPC” instead of ERTS/RPC/PubSub (`docs/docs/architecture.md`).
- References that contradict the current SRQL model (SRQL is embedded in `web-ng` via Rustler/NIF).

### Architecture + Diagrams
- Rewrite `docs/docs/architecture.md` with high-level Mermaid diagrams that reflect:
  - Edge agent capabilities (collectors + embedded runtimes)
  - gRPC streaming ingestion to agent-gateway (including chunking)
  - ERTS/RPC/PubSub path from agent-gateway into the control plane
  - NATS JetStream bulk ingestion path to consumers and CNPG
  - A deployment-agnostic diagram (works for all-in-one Docker Compose or Kubernetes)

**Diagram constraints:**
- Keep Mermaid diagrams high-level (service boxes and protocols), avoid deep implementation details.
- Show the control plane as one “Core Platform” box containing `core-elx`, `web-ng`, and `agent-gateway` (internal clustering happens inside the box).
- Show the agent as one “Edge Agent” box that includes embedded runtimes (sync, SNMP, discovery, mDNS, Wasm plugins).
- For NATS, show the `events` stream and the current core consumers:
  - `zen-consumer`
  - `log-promotion`
  - `db-event-writer`

### Edge Documentation
- Publish a clear “Edge model” that documents:
  - mTLS identity and enrollment
  - `Hello` -> config retrieval flow
  - command bus semantics (bidi gRPC)
  - plugin system (wazero sandbox) and where SDKs live (Go SDK repo, plus future Rust SDK)
  - what runs in-agent (sync integrations, SNMP poller, mapper/discovery, mDNS collector, etc.)

### Deployment and Security
- Update Docker Compose and Helm docs so they match today’s supported matrix:
  - Kubernetes: SPIFFE/SPIRE supported
  - Docker Compose: SPIFFE not supported (non-SPIFFE mTLS bootstrapping only)
  - Podman: not supported
- Remove KV/datasvc configuration guidance (nats-kv) and any “KV for config” narratives.

### Root-Level Docs Consistency
- Align `README.md`, `INSTALL.md`, and Docker quickstart docs with the same component names and flows as the docs site.
- Remove references to legacy UI stacks and legacy control plane components from user-facing docs.

### Proposed “Small Sidebar” Outline (Doc IDs)
This is the intended end-state for the primary docs navigation (exact filenames can vary during implementation, but the structure should remain):

- Overview:
  - `intro`
  - `quickstart`
  - `architecture`
- Deploy:
  - `docker-setup`
  - `helm-configuration`
- Edge:
  - `edge-agents` (or `edge-model`)
  - `edge-agent-onboarding` (merged with `edge-onboarding` if redundant)
  - `wasm-plugins`
- Data:
  - `observability-signals` (or a new “Data pipeline” page that links out to syslog/snmp/netflow/otel as needed)
  - `srql-language-reference` (keep as reference)
- Operations:
  - `troubleshooting-guide`
  - `tools` (serviceradar-tools pod/container and common CLI workflows)
  - `runbooks/*` (keep under Operations, not top-level sprawl)

## Open Questions (Resolve Before Implementation)
- SRQL is embedded in `web-ng` via Rustler/NIF (no separate SRQL service).
- NATS `events` stream consumers are: `zen-consumer`, `log-promotion`, `db-event-writer`.
- Datasvc remains in the shipped stack today (used by core-elx and zen to stay in sync) but is planned to be phased out by release 1.1.0. Documentation should minimize operator-facing coupling to datasvc and avoid “KV as config” narratives.
- For non-Kubernetes deployments: what is the supported, canonical mTLS bootstrap story for edge agents (cert package download, rotation, and revocation)?

## Impact
- Affected specs: edge-architecture, agent-connectivity, agent-configuration, kv-configuration.
- Affected docs: `docs/docs/**` architecture/deploy/edge pages, `docs/sidebars.ts`, root docs (`README.md`, `INSTALL.md`, Docker docs).
- Affected internal context: `openspec/project.md` (must match reality so future OpenSpec work doesn’t re-introduce legacy assumptions).
