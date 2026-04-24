## 1. Documentation IA + Navigation
- [x] 1.1 Redesign `docs/sidebars.ts` into a smaller set of functional sections (intro/quickstart/architecture/deploy/edge/data/troubleshooting).
- [x] 1.2 Identify docs to delete, merge, or rewrite (remove legacy narratives and low-value internal pages from the primary sidebar).
- [x] 1.3 Update internal cross-links for renamed/merged pages and ensure there are no broken doc IDs.

## 2. Architecture + Diagrams
- [x] 2.1 Rewrite `docs/docs/architecture.md` for the current system:
  - Edge agent as a single Go binary with embedded collectors and `wazero` Wasm plugin runtime.
  - Agent -> agent-gateway over mTLS gRPC with streaming (chunked payloads) and command bus.
  - agent-gateway -> control plane over ERTS/RPC/PubSub (not gRPC).
  - Bulk collectors -> NATS JetStream -> consumers -> CNPG.
- [x] 2.2 Replace existing Mermaid diagrams with high-level diagrams (no legacy components; keep data stores and protocols at a clear, readable level).

## 3. Edge Docs
- [x] 3.1 Update/create an “Edge model” doc covering: enrollment, `Hello`, config retrieval, command bus, and operational boundaries.
- [x] 3.2 Update `docs/docs/wasm-plugins.md` to be the canonical plugin doc:
  - `wazero` sandbox model and capability boundaries
  - how plugins are authored and packaged
  - reference the Go SDK repo (and future Rust SDK)
  - document that “Dusk checker” is a Wasm plugin (not a standalone service)
  - document that sync integrations, SNMP poller, mapper/discovery, and mDNS collector run in-agent

## 4. Tools Pod/Container
- [x] 4.1 Add a `docs/docs/tools.md` page that documents the `serviceradar-tools` debugging pod/container:
  - what it is for (safe, preconfigured CLI environment)
  - NATS CLI context setup and common commands (streams, consumers)
  - gRPC `grpcurl` aliases (core, agent, etc.)
  - CNPG helpers (psql via `cnpg-sql`, `cnpg-info`)
  - where it is defined/configured in Helm and Docker Compose

## 5. Deploy + Security Matrix
- [x] 5.1 Update Docker docs to remove SPIFFE/SPIRE guidance and document the supported mTLS bootstrap model for Compose.
- [x] 5.2 Update Helm/Kubernetes docs to document SPIFFE/SPIRE as Kubernetes-only.
- [x] 5.3 Remove Podman references and state it is not supported.
- [x] 5.4 Remove KV/datasvc (nats-kv) configuration guidance and replace with current config delivery paths.

## 6. Root Docs Consistency
- [x] 6.1 Update `README.md` architecture section to match the updated docs.
- [x] 6.2 Update `INSTALL.md`, `DOCKER_QUICKSTART.md`, and docker-specific READMEs to match supported deployment paths and current component names.

## 7. Internal Context Hygiene
- [x] 7.1 Update `openspec/project.md` to remove legacy assumptions (Next.js legacy UI, KV-backed config, SRQL-in-web-ng via Rustler if no longer true).

## 8. Spec deltas
- [x] 8.1 Update edge-architecture spec delta to match agent-gateway ingress + ERTS forwarding model.
- [x] 8.2 Update agent-connectivity spec delta to include bidirectional command bus and streaming constraints.
- [x] 8.3 Update agent-configuration spec delta to match config push/pull behavior and non-KV config delivery.
- [x] 8.4 Update kv-configuration spec delta to remove all remaining nats-kv/datasvc dependencies and rules storage assumptions.

## 9. Validation
- [x] 9.1 Run `openspec validate update-architecture-docs --strict`.
