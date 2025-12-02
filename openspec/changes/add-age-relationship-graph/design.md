## Context
Apache AGE is already bundled in our CNPG images but unused. Checker hosts still leak into inventory as phantom devices (e.g., sysmon/mapper/zen health probes showing up as `agent` devices). We need a first-class relationship graph (devices, collectors, services/checkers, interfaces, capabilities) so the inventory can distinguish collector-owned services from monitored targets and show topology/metrics badges.

## Goals / Non-Goals
- Goals: bootstrap an AGE graph in CNPG, define node/edge schema, ingest registry/mapper/checker data, ingest DIRE outputs, expose graph queries for inventory/SRQL/AI, provide rebuild/backfill and drift detection.
- Non-Goals: replace relational tables for registry/history, redesign SRQL planner wholesale, or add new external stores beyond AGE inside CNPG.

## Decisions
- Graph: create `serviceradar` AGE graph; enable `age` extension for core/SRQL connections.
- Nodes: `Device` (canonical_device_id), `Collector` (serviceradar:agent|poller), `Service` (internal + external, keyed by service device ID), `Interface` (device/name), optional `Capability` nodes for SNMP/OTEL/sysmon/healthcheck.
- Edges: `HOSTS_SERVICE` (Collector → Service), `RUNS_CHECKER` (Collector → Service or CheckerDefinition), `TARGETS` (Service/Checker → Device), `HAS_INTERFACE`/`ON_DEVICE` (Device ↔ Interface), `CONNECTS_TO` (Interface ↔ Interface), `PROVIDES_CAPABILITY` (Service/Device ↔ Capability), `REPORTED_BY` (Service/Device → Collector for provenance).
- Ingestion: DIRE emits canonical device updates into AGE; core registry emits Cypher `MERGE` writes; mapper interface pipeline writes Interfaces and neighbor CONNECTS_TO edges via DIRE-resolved device IDs; checker ingestion writes RUNS_CHECKER/TARGETS without promoting collector host IPs to Device nodes; writers tolerate AGE failures (queue/retry) without blocking registry.
- Queries: DAO/API returns device neighborhoods (collector → service/checker → target → interfaces + capabilities) with flags for collector-owned services; SRQL gains graph-backed primitives for inventory/topology; provide stored Cypher templates for UI and AI use.
- Backfill: job to rehydrate graph from unified_devices (DIRE), service registry, mapper interface inventory, and recent checker history.
- SRQL integration: add a dedicated graph entity `device_graph` (`in:device_graph`) that issues AGE `cypher(...)` and casts results to `jsonb` to avoid `agtype` bindings; normalize graph_path/search_path per session for safety; return structured JSON (device, collectors, services/checkers with collector-owned flag, targets, interfaces, capability badges) instead of raw Cypher rows; extend SRQL test harness to seed the AGE graph with a minimal neighborhood and assert the contract.

## Risks / Trade-offs
- AGE ingestion lag could desync UI badges from registry state → mitigate with retry + drift metrics and rebuild job.
- Graph growth from checker history → limit to current edges (latest per target/service) and keep history in relational tables.
- Multi-tenant concerns if we later split graphs per customer → start with namespaced IDs to allow future partitioning.

## Migration Plan
- Add migration to create graph + indexes; deploy writer paths behind a feature flag.
- Run backfill job once deployed; monitor drift metrics; adjust retention limits for checker→target edges if needed.

## Open Questions
- Should capability badges live as dedicated nodes or edge properties for simpler queries?
- Do we need per-checker execution edges (history) or only latest per service/target? (lean latest + relational history)
- Should SRQL expose graph traversal (AGE cypher) directly or only through curated APIs?
