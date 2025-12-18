# Product Requirements Document (PRD): Rust BMP (BGP) Collector + OCSF Pipeline

| Metadata | Value |
|----------|-------|
| Date     | 2025-12-18 |
| Author   | @mfreeman451 |
| Status   | Draft |
| Links    | https://github.com/carverauto/serviceradar/issues/2183, https://github.com/carverauto/serviceradar/issues/859, https://github.com/nxthdr/risotto, https://schema.ocsf.io/1.7.0/classes/network_activity |

## 1. Summary

ServiceRadar needs a **Rust-based BMP (BGP Monitoring Protocol) collector daemon** that can run on the edge or in-cluster, accept BMP sessions from routers/route reflectors, decode BMP/BGP messages, and publish records to a **message broker** (initially **NATS JetStream**). Downstream processing should remain pipeline-based (not embedded into the collector) by using the existing stateless rule-based Zen engine (`serviceradar-zen`) to transform raw BMP events into an **OCSF 1.7.0**-aligned schema (using the `network_activity` class), republish to a separate subject, and then persist via **`db-event-writer`** into CNPG for SRQL queries and UI dashboards.

The collector must keep its broker integration behind an abstraction so ServiceRadar can support additional brokers in the future (e.g., `iggy.rs`).

## 2. Problem Statement

ServiceRadar does not currently have a first-class ingest path for control-plane telemetry from BGP devices. Without BMP ingestion, it is hard to build:

- BGP session health monitoring (peer up/down, resets, flaps)
- Route update visibility (update/withdraw rates)
- Prefix counters and policy troubleshooting workflows
- Correlation between topology/inventory and routing behavior over time

The platform needs a robust, deployable BMP collector that integrates with existing ServiceRadar patterns: broker-first buffering, stateless ETL in Zen, and persistence in CNPG via `db-event-writer`.

## 3. Goals

- Provide a **Rust BMP collector** capable of ingesting BMP streams and publishing decoded events to NATS JetStream.
- Keep the collector generic: no OCSF mapping logic in the collector; do transformation in `serviceradar-zen`.
- Use an abstract broker interface so we can add alternate brokers later.
- Persist OCSF `network_activity` records in CNPG in a queryable form.
- Add a UI dashboard for BGP/BMP observability and troubleshooting.

## 4. Non-Goals (Initial Release)

- Full BGP analytics suite (path hunting, policy simulation, RPKI validation, etc).
- Long-term historical storage in external lakehouse systems (Iceberg/Parquet/ClickHouse) as part of this PRD.
- Perfect coverage of all BMP/BGP optional/transitive attributes on day one (store extras in `unmapped` or metadata-friendly fields).

## 5. Primary Use Cases

- **NOC operator**: see which peers are flapping and when.
- **Network engineer**: inspect update/withdraw rates by peer or ASN over time.
- **SRE/platform**: operate the collector at scale (health checks, backpressure behavior, metrics).

## 6. Proposed Architecture (High-Level)

```mermaid
flowchart LR
  Routers["BGP devices<br/>export BMP over TCP"] -->|TCP 11019 (typical)| Collector["serviceradar-bmp-collector<br/>Rust (risotto-based)"]
  Collector -->|raw BMP events| Broker["Message Broker<br/>NATS JetStream"]
  Broker -->|consume raw| Zen["serviceradar-zen<br/>rule-based ETL"]
  Zen -->|publish OCSF network_activity| Broker
  Broker -->|consume OCSF| DBWriter["db-event-writer"]
  DBWriter --> CNPG["CNPG/Timescale"]
  Web["Web UI"] --> Core["Core/SRQL API"]
  Core --> CNPG
```

## 7. Functional Requirements

### 7.1 Rust BMP Collector Daemon

#### FR-1: Deployment modes
- The collector SHALL support running:
  - **In-cluster** (Kubernetes), exposed via a TCP Service.
  - **Edge/on-prem** (systemd, docker-compose), listening on TCP.

#### FR-2: Protocol support (MVP)
- The collector SHALL accept BMP sessions and decode BMP messages into a structured representation.
- The collector SHOULD support the common BMP message types used for monitoring:
  - Initiation
  - Peer Up
  - Peer Down
  - Route Monitoring
  - Statistics Report
  - Termination

#### FR-3: Use upstream library where possible
- The implementation SHOULD leverage `nxthdr/risotto` (MIT licensed) as the core BMP decoding/parsing library.
- Any gaps needed for ServiceRadar integration SHOULD be upstreamable (PRs) where practical.

#### FR-4: Broker abstraction
- The collector SHALL publish decoded BMP events through an internal broker interface (e.g., `Publisher` trait).
- The initial broker implementation SHALL target NATS JetStream.
- The collector SHOULD support future alternate brokers without redesigning the collector core.

#### FR-5: Raw message publication
- Raw BMP events SHALL be published to a dedicated subject prefix (name TBD), for example:
  - `bmp.raw`
- OCSF-transformed records SHALL be published to a separate subject prefix (name TBD), for example:
  - `bmp.ocsf.network_activity`
- The raw payload SHOULD be stable across languages (JSON or protobuf). The initial choice MUST:
  - allow Zen to access key fields needed for OCSF mapping
  - preserve additional BMP/BGP data for future analytics (store extras in an `unmapped`-style field)

#### FR-6: Reliability and buffering
- The collector SHALL tolerate temporary broker unavailability without crashing.
- The collector SHALL provide bounded buffering with configurable backpressure/drop behavior.
- The collector SHOULD expose clear metrics for buffered messages and drops.

#### FR-7: Security
- Collector-to-broker communication SHALL support mTLS consistent with existing ServiceRadar deployments.
- When running in SPIFFE/SPIRE environments, the collector SHOULD support SPIFFE workload identity patterns already used by other ServiceRadar services.

#### FR-8: Observability
- The collector SHALL provide:
  - health endpoint (or gRPC health) and readiness semantics
  - structured logs
- The collector SHOULD expose metrics including:
  - active BMP sessions / connected exporters
  - messages received/sec (by BMP message type)
  - decode errors/sec
  - bytes received/sec
  - publish success/failure counters
  - buffer depth / drops

### 7.2 Zen Engine Transformation (`serviceradar-zen`)

#### FR-9: OCSF schema commitment
Zen output MUST validate against the OCSF 1.7.0 JSON schema for the `network_activity` class:
- https://schema.ocsf.io/1.7.0/classes/network_activity

#### FR-10: Event mapping (MVP)
Zen MUST map BMP-derived events into OCSF `network_activity` in a consistent way so dashboards and SRQL can rely on it.

Minimum mappings:
- Base requirements:
  - `class_uid = 4001` and `category_uid = 4`
  - `severity_id = 1` (Informational) unless a higher severity is explicitly derived by policy
  - `cloud.provider` populated (default `"on_prem"`, configurable)
  - `metadata.product = "ServiceRadar"` and `metadata.version` populated
  - `osint = []` (empty array) by default
- Timestamps:
  - `time` from BMP message time when available; otherwise collector receive time
- Endpoints:
  - `src_endpoint.ip` set to BMP exporter/router address
  - `dst_endpoint.ip` set to collector address (or service name/IP)
  - `connection_info.protocol_num = 6` (TCP) and `dst_endpoint.port = 11019` when known

BMP message type to OCSF mapping (proposed defaults):
- Peer Up:
  - `activity_id = 1` (Open), `type_uid = 400101`
- Peer Down:
  - `activity_id = 2` (Close), `type_uid = 400102`
  - if reset semantics are available, MAY use `activity_id = 3` (Reset), `type_uid = 400103`
- Route Monitoring / Statistics Report:
  - `activity_id = 6` (Traffic), `type_uid = 400106`

Non-core BMP/BGP details (peer ASN, peer IP, AFI/SAFI, NLRI, withdrawals, counters, reason codes) SHOULD be included under `unmapped` (or a similar JSON subtree) without breaking schema validation.

### 7.3 Persistence (`db-event-writer` + CNPG)

#### FR-11: Persist OCSF `network_activity` records
- `db-event-writer` SHALL be updated to persist OCSF `network_activity` records in CNPG in a queryable form.
- The persistence strategy MUST support powering dashboards and SRQL aggregations without requiring full JSON parsing in the UI.

Implementation options (choose one during design):
1. Dedicated table for OCSF `network_activity` (recommended), with query-friendly columns + JSONB payload.
2. Reuse an existing table (e.g., `events`) for the full payload, plus add summary columns elsewhere for common aggregations.

### 7.4 SRQL + UI

#### FR-12: Query support
- SRQL MUST support querying the persisted BMP/OCSF records for:
  - peer up/down over time
  - update/withdraw counts or rates over time
  - top peers by update volume

#### FR-13: BGP/BMP dashboard (MVP)
- The UI SHALL provide a dashboard with at least:
  - peer session timeline (up/down/reset)
  - update volume over time (overall and by peer)
  - top peers by updates/withdraws
  - recent "peer down" reasons (when available)

## 8. Non-Functional Requirements

- **Performance**: sustain BMP ingestion for small/medium networks; include benchmark targets in acceptance.
- **Scalability**: support horizontal scaling of Zen and DB writers (JetStream queue groups / consumers).
- **Operability**: predictable config, clear logs/metrics, and safe failure modes.
- **Compatibility**: run in docker-compose and k8s; align with ServiceRadar mTLS/SPIFFE conventions.

## 9. Milestones / Phases (Suggested)

1. Collector MVP: BMP accept + decode + publish raw events to JetStream.
2. Zen ETL MVP: map to OCSF `network_activity`, republish to OCSF subject.
3. Persistence MVP: db-event-writer persists OCSF records into CNPG.
4. SRQL + UI: queries and dashboard for sessions and update rates.
5. Hardening: backpressure tuning, scale tests, docs/runbooks.

## 10. Risks & Mitigations

- **Schema fit**: BMP is routing/control-plane telemetry; `network_activity` may be a pragmatic but imperfect semantic home.
  - Mitigation: keep full structured data under `unmapped` so we can evolve mappings later without losing fidelity.
- **High-volume bursts**: route storms can create spikes.
  - Mitigation: bounded buffers, publish batching, queue group scaling, drop metrics and alerting.
- **Interoperability**: routers vary in BMP support and content.
  - Mitigation: rely on upstream library parsing; store unknown fields in `unmapped`; add compatibility fixtures.

## 11. Open Questions

- What is the canonical raw payload format: protobuf vs JSON (and do we need a new proto like `proto/bmp/bmp.proto`)?
- What subject/stream naming conventions should we standardize on for `bmp.raw` and OCSF output?
- Which CNPG table layout best supports SRQL queries and dashboards for BGP telemetry?
- How do we represent "peer identity" canonically (exporter IP, peer IP, ASN) for grouping/aggregation?
