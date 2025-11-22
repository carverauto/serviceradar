# Product Requirements Document: CNPG + TimescaleDB + Apache AGE Unified Telemetry Store

## 1. Executive Summary

ServiceRadar’s next-generation telemetry platform moves away from the legacy CNPG/ClickHouse stack and standardizes on **CloudNativePG (CNPG)** running **PostgreSQL 16** with the **TimescaleDB** and **Apache AGE** extensions enabled. Timescale hypertables handle all time-series metrics, events, and logs with tiered compression/retention, while Apache AGE keeps a native property graph of devices, collections, and discovered relationships. SRQL (Rust) becomes the single query surface, compiling into SQL that targets hypertables for metrics/logs and AGE graph traversals for topology queries.

This PRD describes how telemetry flows into CNPG, which hypertables we create, how continuous aggregates feed dashboards/alerts, and how AGE models relationships between devices, services, agents, pollers, metrics, and mapper/discovery outputs. The end state delivers one operational data store for streaming + historical analytics, consistent graph semantics, and simpler failover/backups through CNPG.

## 2. Goals & Non-Goals

**Goals**
1. Land all telemetry in CNPG via Timescale hypertables with native retention/compression policies.
2. Introduce Apache AGE schemas for topology, discovery, and configuration relationships.
3. Update SRQL planner/executor to emit SQL that joins hypertables and AGE traversals.
4. Provide clear ingestion flows from agents/pollers → core → CNPG (including high-ingest paths for metrics/logs/events).
5. Document operational practices for rolling schema migrations, hypertable management, and AGE graph maintenance.

**Non-Goals**
- Replacing Kafka/NATS as transport layers (unchanged).
- Rewriting agents/pollers beyond required schema changes.
- Delivering a full UI overhaul (handled separately).

## 3. Target Users

| User | Need | How this PRD helps |
|------|------|--------------------|
| Network + Platform Engineers | Low-latency metrics/logs correlated with device relationships | Hypertables + continuous aggregates | 
| SRE / Observability Teams | Unified query interface for anomalies and topology | SRQL over Timescale + AGE |
| Mapper/Discovery Operators | Persisted graph showing collections/services/interfaces | Apache AGE vertices/edges |
| SaaS Ops | Simple HA/backups | CNPG-managed cluster with WAL streaming |

## 4. Proposed Architecture

```
              ┌────────────┐      ┌────────────┐
              │ Agents &   │ gRPC │ Pollers &  │
              │ Checkers   │─────▶│ Core APIs  │
              └────────────┘      └────────────┘
                     │                   │
                     │ batched ingest    │
                     ▼                   │
              ┌────────────────────────────────┐
              │   CNPG (Postgres 16 +          │
              │   TimescaleDB + Apache AGE)    │
              │   • Hypertables (metrics/logs) │
              │   • Continuous aggregates      │
              │   • AGE graph schema           │
              └────────────────────────────────┘
                             │
                   ┌─────────┴─────────┐
                   │ Rust SRQL Service │
                   │ (Diesel + AGE SQL)│
                   └─────────┬─────────┘
                             │
                    Dashboards / APIs / Alerts
```

### 4.1 CNPG Cluster Layout
- **Primary**: 3-node CNPG cluster (one primary, two replicas) with WAL archiving in object storage.
- **Extensions**: TimescaleDB 2.15+, Apache AGE 1.5+, `pg_cron`, `pg_partman` (optional for standard tables).
- **Namespaces**:
  - `telemetry_ts`: hypertables + continuous aggregates.
  - `telemetry_graph`: Apache AGE graph catalog.
  - `config_core`: reference tables (tenants, credentials, inventories).

### 4.2 Timescale Hypertables

| Hypertable | Partitioning | Purpose |
|------------|--------------|---------|
| `telemetry_ts.metric_samples` | Time partition 1 day, `tenant_id` space | SNMP, sysmon, CPU, disk, interface counters |
| `telemetry_ts.log_events` | Time partition 1 day, hash by `tenant_id` | Syslog, application logs |
| `telemetry_ts.event_stream` | Time partition 3 days, `tenant_id` | Traps, alerts, anomaly detections |
| `telemetry_ts.discovery_snapshots` | Time partition 7 days | Outputs from mapper/discovery engine (pre-graph ingestion) |

Policies:
- Compression after 3 days, drop after 90 days for metrics/logs (tenant override possible).
- Continuous aggregates (CA):
  - `metric_samples_ca_5m`: average/percentile metrics per 5 minute bucket.
  - `log_events_ca_1h`: counts of log severity per hour.
  - `event_stream_ca_1m`: counts grouped by event types, feeding alerting.

### 4.3 Apache AGE Graph Model

Create a graph `topology_graph` with:

**Vertices**
- `Device` (properties: `tenant_id`, `device_id`, `hostname`, `os`, `site`)
- `Collection` (group of devices for policy/queries)
- `Service` (representing discovered services + SRQL service definitions)
- `Agent` (deployed agent nodes)
- `Poller`
- `Metric` (logical metric definitions)
- `Interface`

**Edges**
- `(:Agent)-[:MANAGES]->(:Device)`
- `(:Poller)-[:COLLECTS]->(:Metric)`
- `(:Device)-[:HAS_INTERFACE]->(:Interface)`
- `(:Device)-[:PART_OF]->(:Collection)`
- `(:Service)-[:RUNS_ON]->(:Device)`
- `(:Metric)-[:OBSERVED_AT]->(:Interface)`
- `(:Device)-[:RELATES_TO]->(:Device)` (topology adjacency LLDP/CDP etc.)

AGE operations:
- Mapper writes discovery snapshots into `telemetry_ts.discovery_snapshots`.
- Background job (Rust or SQL procedure) converts snapshots into graph upserts (MERGE semantics).
- SRQL graph queries compiled via AGE’s openCypher subset.

## 5. Data Flow & Ingestion

1. **Agent/Checker output** (SNMP, sysmon, etc.) → gRPC → Core ingestion API.
2. Core writes raw samples into Timescale hypertables using COPY or batched INSERT (via Diesel).
3. `pg_cron` job triggers compression/retention policies nightly.
4. Discovery engine publishes JSON snapshots; core stores them in `telemetry_ts.discovery_snapshots`.
5. A `graph_loader` job reads new snapshots and uses AGE stored procedures to merge vertices/edges (idempotent per snapshot id).
6. SRQL queries pick the right storage target:
   - Metric/log/time window queries → hypertables or continuous aggregates.
   - Topology/service relationship queries → AGE graph.
   - Mixed queries use CTEs: fetch devices via AGE path, join device IDs back to hypertable views.

### Ingestion Example (Metrics)
```sql
SELECT create_hypertable('telemetry_ts.metric_samples', 'bucket_time',
                         chunk_time_interval => INTERVAL '1 day',
                         partitioning_column => 'tenant_id',
                         number_partitions => 16,
                         if_not_exists => TRUE);

SELECT add_retention_policy('telemetry_ts.metric_samples', INTERVAL '90 days');
SELECT add_compression_policy('telemetry_ts.metric_samples', INTERVAL '3 days');
```

Rust ingestion snippet:
```rust
diesel::insert_into(metric_samples::table)
    .values(&records)
    .on_conflict_do_nothing()
    .execute(&mut conn)?;
```

### Graph Merge Procedure (Pseudo-SQL)
```sql
SELECT *
FROM cypher('topology_graph', $$
  UNWIND $snapshots AS snap
  MERGE (d:Device {tenant_id: snap.tenant_id, device_id: snap.device_id})
    SET d.hostname = snap.hostname, d.os = snap.os
  WITH d, snap
  UNWIND snap.services AS svc
  MERGE (s:Service {tenant_id: snap.tenant_id, name: svc.name})
  MERGE (d)-[:RUNS_ON]->(s)
$$) AS (result agtype);
```

## 6. SRQL Implications

- **Planner**: extend AST with two execution targets: `timescale` and `graph`. `in:devices` default to hypertables but allow `GRAPH()` hint to run topological traversals.
- **Executions**:
  - `SELECT ... FROM telemetry_ts.metric_samples` using indexes on `(tenant_id, bucket_time, canonical_path)`.
  - `SELECT * FROM cypher('topology_graph', ...)` for graph sections.
  - Mixed queries: planner emits `WITH graph_result AS (...) SELECT ... FROM telemetry_ts.metric_samples JOIN graph_result ...`.
- **Pagination**: hypertables use `ORDER BY bucket_time DESC LIMIT X OFFSET Y`; graph queries use `skip`/`limit`.

## 7. Operations & Reliability

- **Backups**: rely on CNPG WAL archiving + base backups; for Timescale, ensure compressed chunks are part of backups; for AGE, graph metadata is stored in relational tables so WAL covers it.
- **Monitoring**: new metrics from CNPG exporter for hypertable chunk counts, compression lag, graph loader latency.
- **Schema Migrations**:
  - Use `sqitch` or Diesel migrations for hypertables.
  - Graph schema versioned via SQL files executed by CNPG hooks.
  - Mapper/discovery deployments must support new schema fields before enabling new graph edges.

## 8. Timeline & Milestones

| Milestone | Scope | Target |
|-----------|-------|--------|
| M1 – CNPG foundation | Stand up CNPG cluster, enable Timescale + AGE, port existing tables | +2 weeks |
| M2 – Hypertable ingest | Update core ingestion paths + compression/retention policies | +4 weeks |
| M3 – Graph loader | Build snapshot ingestion + AGE merge jobs, expose SRQL graph syntax | +6 weeks |
| M4 – SRQL GA | SRQL powering dashboards against hypertables + graph | +8 weeks |
| M5 – Cleanup | Remove leftover CNPG artifacts, finalize docs/runbooks | +9 weeks |

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Timescale write amplification | Higher CPU/disk during compression | Tune chunk interval + compression lag per tenant; monitor via CNPG |
| AGE maturity | Less tooling vs. Neo4j | Keep graph loader idempotent; wrap queries via SRQL abstractions |
| Mixed workload on CNPG | Resource contention | Use separate pools for ingestion vs. SRQL reads; consider read replicas |
| Migration complexity | Downtime risk | Stage migrations in dev -> staging; use CNPG rolling updates |

## 10. Success Criteria

1. All telemetry metrics/logs/events land in Timescale hypertables with retention/compression active.
2. Mapper/discovery outputs visible via AGE vertices/edges and queryable through SRQL.
3. Dashboards/alerts run solely against CNPG (no CNPG dependence).
4. Operational runbooks cover backups, failover, and schema evolution.
5. SRQL trending + topology queries run within SLA (<1s P95 for aggregated metrics, <2s P95 for graph traversals).
