# Product Requirements Document (PRD): Rust NetFlow Collector + OCSF Pipeline

| Metadata | Value |
|----------|-------|
| Date     | 2025-12-18 |
| Author   | @mfreeman451 |
| Status   | Draft |
| Links    | https://github.com/carverauto/serviceradar/issues/2181, https://github.com/carverauto/serviceradar/issues/611, `proto/flow/flow.proto` (FlowMessage), existing `netflow_metrics` CNPG hypertable |

## 1. Summary

ServiceRadar needs a **Rust-based NetFlow collector daemon** that can run on the edge or in-cluster, ingest NetFlow/IPFIX flow exports, and publish flow records to a **message broker** (initially **NATS JetStream**). Downstream processing should remain **pipeline-based** (not embedded into the collector) by using the existing **stateless rule-based Zen engine** (`serviceradar-zen`) to transform raw flow records into an **OCSF 1.7.0**-aligned schema (primarily `network_activity`), then persist the results via **`db-event-writer`** and expose them via **SRQL** and the **Web UI**.

This PRD focuses on an end-to-end "flows" pipeline that is consistent with ServiceRadar's broker-first architecture, while keeping the collector generic and swappable. The canonical semantic schema for flow telemetry is **OCSF 1.7.0 `network_activity`**.

## 2. Problem Statement

ServiceRadar currently lacks a first-class, production-ready path to ingest high-volume flow telemetry (NetFlow v5/v9, IPFIX; potentially sFlow) in a way that:

- Supports **edge** and **cluster** deployments.
- Uses **reliable buffering** and **at-least-once** delivery semantics.
- Avoids embedding heavy schema/ETL logic directly into the collector.
- Aligns stored data with an industry schema (OCSF) for long-term flexibility.
- Enables SRQL queries against flows and powers a NetFlow dashboard in the UI.

## 3. Goals

- Provide a **Rust collector daemon** that ingests flow exports and publishes them to a broker.
- Make the broker interface **abstract** so additional brokers can be added later (e.g., `iggy.rs`).
- Keep collector output **generic**, with OCSF mapping performed downstream via `serviceradar-zen`.
- Persist transformed flow data in CNPG such that **SRQL `flows` becomes functional**.
- Add initial **UI dashboards** for common "top talkers / top ports / bandwidth over time" workflows.

## 4. Non-Goals (Initial Release)

- Full network forensics (PCAP capture, payload inspection).
- Advanced anomaly detection / ML / causal inference (explicitly future work).
- Replacing ServiceRadar's entire observability storage model or adding large new storage backends (e.g., Iceberg/ClickHouse) as part of this PRD.
- Perfect fidelity for all NetFlow/IPFIX vendor fields on day one (vendor extensions may be stored as metadata).

## 5. User Personas / Primary Use Cases

- **Network Administrator**: wants "top talkers" and "top ports" from the last 15 minutes / 24 hours.
- **Security Analyst**: wants to pivot on a source/destination IP and see recent flow history during incident response.
- **Platform Engineer**: wants a collector that can be deployed and upgraded reliably, with clear configuration and observability.

## 6. Proposed Architecture (High-Level)

```mermaid
flowchart LR
  Exporters[Network devices\n(export NetFlow/IPFIX)] -->|UDP 2055/4739...| Collector[serviceradar-netflow-collector\n(Rust)]
  Collector -->|raw flow records| Broker[(Message Broker\nNATS JetStream)]
  Broker -->|consume raw| Zen[serviceradar-zen\nrule-based ETL]
  Zen -->|publish OCSF| Broker
  Broker -->|consume OCSF| DBWriter[db-event-writer]
  DBWriter --> CNPG[(CNPG/Timescale)]
  Web[Web UI] --> Core[Core/SRQL API]
  Core --> CNPG
```

## 7. Functional Requirements

### 7.1 Rust NetFlow Collector Daemon

#### FR-1: Deployment modes
- The collector SHALL support running:
  - **In-cluster** (Kubernetes), exposed via a UDP Service.
  - **Edge/on-prem** (systemd, docker-compose), listening on UDP.

#### FR-2: Protocol support
- The collector SHALL support NetFlow v9 and IPFIX ingestion.
- The collector SHOULD support NetFlow v5 ingestion.
- The collector MAY add sFlow in a later phase if required.

#### FR-3: Generic output and broker abstraction
- The collector SHALL publish decoded flow records to a broker through an internal interface (e.g., `Publisher` trait), to allow future broker implementations.
- The initial broker implementation SHALL target NATS JetStream.
- The collector SHALL NOT perform OCSF transformation; transformation is handled downstream.

#### FR-4: Message format for raw flows
- Raw flow messages SHALL be published in a format consumable by downstream services and stable across languages.
- The preferred raw format for the pipeline is the existing protobuf message:
  - `flowpb.FlowMessage` defined in `proto/flow/flow.proto`.
- Each published message SHOULD include enough exporter context to support device attribution (e.g., exporter IP / sampler address, observation domain ID).

#### FR-5: Broker stream and subject conventions
- Raw flow messages SHALL be published to a dedicated JetStream stream (name TBD) and subject prefix (name TBD), for example:
  - `flows.raw.netflow` (raw `flowpb.FlowMessage` frames).
- OCSF-transformed flow messages SHALL be published to a separate subject prefix, for example:
  - `flows.ocsf.network_activity`.

#### FR-6: Reliability and buffering
- The collector SHALL tolerate temporary broker unavailability without crashing.
- The collector SHALL provide bounded buffering (in-memory) with clear backpressure behavior:
  - Drop policy and/or rate limiting MUST be configurable.
  - Metrics MUST reflect drops/backpressure events.

#### FR-7: Security
- Collector-to-broker communication SHALL support mTLS consistent with existing ServiceRadar deployments.
- When running in environments using SPIFFE/SPIRE, the collector SHOULD support SPIFFE workload identity patterns already used by other Rust components.

#### FR-8: Observability
- The collector SHALL emit structured logs and basic health status.
- The collector SHOULD expose metrics sufficient to operate it at scale:
  - packets received/sec
  - flows decoded/sec
  - decode errors/sec (by type/version/template miss)
  - publish success/failure counters
  - queue depth / buffered messages

### 7.2 Zen Engine Transformation (`serviceradar-zen`)

#### FR-9: Decode + ETL rules
- `serviceradar-zen` SHALL be able to consume raw flow messages from JetStream and present the flow fields to rules.
- Zen rules SHALL emit OCSF output using the `network_activity` class.
- The output SHALL be republished back to JetStream on the OCSF subject prefix.

#### FR-10: OCSF schema commitment (MVP)
Zen output MUST validate against the OCSF 1.7.0 JSON schema for the `network_activity` class:
- https://schema.ocsf.io/1.7.0/classes/network_activity

For MVP, the pipeline SHALL produce `network_activity` records with:
- `class_uid = 4001` and `category_uid = 4` (Network Activity)
- `activity_id = 6` (Traffic) and `type_uid = 400106` (Network Activity: Traffic)
- `severity_id = 1` (Informational) unless a higher severity is explicitly derived by policy
- `time` set from the flow record timestamp (prefer exporter time when reliable; otherwise collector receive time)
- `src_endpoint.ip`, `dst_endpoint.ip`, `src_endpoint.port`, `dst_endpoint.port` populated when known
- `connection_info.protocol_num` populated from L4 protocol number when known
- `traffic.bytes` and `traffic.packets` populated when known
- `cloud.provider` populated (default: `"on_prem"`, configurable)
- `metadata.product = "ServiceRadar"` and `metadata.version` populated (build/version/commit)
- `osint = []` (empty array) by default

Any unmapped or vendor-specific attributes SHOULD be carried in `unmapped` or `metadata`-adjacent fields per OCSF guidance, without breaking schema validation.

### 7.3 Persistence (`db-event-writer` + CNPG)

#### FR-11: Persist OCSF `network_activity` records
- `db-event-writer` SHALL be updated to persist OCSF `network_activity` records in CNPG in a queryable form.
- The persistence strategy MUST support powering SRQL `flows` queries and UI dashboards without requiring full JSON parsing client-side.

Implementation options (choose one during design):
1. **Dedicated table** for OCSF `network_activity` (recommended), with core query columns plus a JSONB payload for the full event.
2. **Reuse `netflow_metrics`** for core columns and store the OCSF payload (or the remainder) in `metadata`.
3. Store OCSF as `events.raw_data` only (acceptable only for a short-lived MVP if SRQL can still efficiently support required aggregations).

### 7.4 SRQL (`flows` entity)

#### FR-12: Enable `flows` queries
- SRQL SHALL support `SHOW flows ...` and basic `stats:` aggregations used by the UI.
- `in:flows` SHALL map to the flow storage defined in FR-11.
- The existing UI default query MUST be supported or updated to match the canonical schema:
  - `in:flows time:last_24h stats:"sum(bytes_total) as total_bytes by connection.src_endpoint_ip" sort:total_bytes:desc limit:25`

### 7.5 Web UI Dashboards

#### FR-13: NetFlow dashboard (MVP)
- The Network dashboard's `Netflow` tab SHALL display at least:
  - Top talkers (by bytes)
  - Top destinations (by bytes)
  - Top ports (by bytes or packet count)
  - Time series of total bytes (or bytes/sec) over a selected window
- The UI SHALL query data via SRQL (preferred) or Core API endpoints (if SRQL is not sufficient).

## 8. Non-Functional Requirements

- **Performance**: sustain high flow ingest rates appropriate for small/medium networks; include benchmarks in acceptance.
- **Scalability**: support horizontal scaling of Zen consumers and DB writers via queue groups/consumer groups.
- **Operability**: provide clear configuration, health checks, and actionable logs/metrics.
- **Compatibility**: support the existing ServiceRadar mTLS/SPIFFE deployment model; work in docker-compose and k8s demo stacks.

## 9. Milestones / Phases (Suggested)

1. **Collector MVP**
   - Rust daemon ingests NetFlow/IPFIX and publishes `flowpb.FlowMessage` to JetStream.
2. **Zen ETL MVP**
   - Rule(s) convert raw flow records into OCSF `network_activity` JSON.
3. **Persistence MVP**
   - `db-event-writer` persists flows in CNPG (selected FR-11 strategy).
4. **SRQL + UI**
   - SRQL `flows` entity works; UI netflow tab renders real data.
5. **Hardening**
   - Backpressure tuning, drop policies, template caching strategy, scale tests, docs/runbooks.

## 10. Risks & Mitigations

- **High volume / backpressure**: JetStream and consumers can be overwhelmed.
  - Mitigation: bounded buffering, publish batching, queue group scaling, drop metrics + alerting.
- **Schema drift**: NetFlow/IPFIX vendor fields vary widely.
  - Mitigation: core fields normalized + store remainder in metadata; rules evolve independently.
- **SRQL mismatch**: UI queries assume a `flows` schema that is not yet implemented.
  - Mitigation: define canonical `flows` schema early and ensure SRQL translator supports it.

## 11. Open Questions

- What is the canonical **subject naming** and JetStream stream layout for raw vs OCSF flows?
- Should we standardize on `flowpb.FlowMessage` as the raw wire format, or publish raw vendor JSON?
- Which FR-11 persistence strategy is preferred (new OCSF table vs reuse `netflow_metrics`)?
- Do we need multi-tenancy/partitioning concepts for flows at ingest time (e.g., `partition`)?
- What retention window is required for flows in CNPG for the MVP, and do we need downsampling?

## 12. References

- OCSF `network_activity` class: https://schema.ocsf.io/1.7.0/classes/network_activity
- Related issues: #2181, #611
- Existing PRD-01 (NetFlow): `sr-architecture-and-design/prd/01-netflow.md` (may contain outdated storage assumptions)
