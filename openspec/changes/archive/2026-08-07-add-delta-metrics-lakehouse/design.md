## Context
SaaS tenancy is decided: each customer gets a dedicated CNPG instance and a
dedicated NATS instance — no shared super-cluster. That removes the shared-primary
failure-domain and catalog-bloat problems, but it does not change physics: one
CNPG primary still cannot absorb a high-rate tenant's raw firehose. Measured
single-primary throughput is ~6.3k (insert_all) to ~19.7k (COPY) rows/sec; the
row-store tax is structural.

The original 50k projection (5.95M rows/sec) scaled a payload that was 94%
per-process sysmon rows. With process rows capped to top-25 (already shipped) the
corrected target is ~350k-590k rows/sec at 50k agents, and the near-term
~2,500-agent target is roughly 15k-30k rows/sec — which tuned CNPG can serve
today. So the urgency is tenant- and scale-dependent, which is why task 2 is a
measurement gate, not an assumption.

The query side already favors tiering: ~15 CAGGs exist and SRQL auto-routes
> 6h metric windows to hourly rollups. Raw points are needed only for
short-window/latest graphing and sub-6h drill-down. The central store's real job
is recent raw + rollups + metadata.

## Goals
- Move long-retention raw metric history off the OLTP primary into a columnar
  lakehouse built for append-only scans.
- Keep recent raw + rollups + metadata in CNPG so live graphing and dashboards
  stay fast on the existing CAGG tier.
- Provide one SRQL query surface that spans both tiers, including federated
  long-range graphing across CNPG (recent) and Delta (history).
- Decide the store from a measured per-agent rate, not a projection of a
  pathological payload.

## Non-Goals
- Pursue TDengine or Iggy (explicitly dropped; this change supersedes those lanes
  of `add-rust-tdengine-analytics`).
- Remove CNPG. CNPG keeps recent raw, rollups, metadata, alerts, findings, and
  capacity forecasts.
- Change the SRQL language or result shape. Only the execution backend for
  long-range/raw metric entities changes.
- Build a multi-node distributed query cluster. DuckDB is per-tenant,
  scale-up-per-query; partitioning provides the scan reduction.

## Decisions
- **Delta Lake as the raw tier**, written by a Rust delta-rs writer consuming the
  metrics JetStream durable. Delta is chosen over Iceberg primarily for Rust-native
  write maturity (delta-rs / delta-kernel-rs); DuckDB, ClickHouse, Spark, and
  Trino can all read Delta, so the format choice does not lock the query engine.
- **DuckDB as the analytical/federation engine.** DuckDB reads Delta via its
  `delta`/`httpfs` extensions and attaches CNPG via the `postgres` extension, so a
  single query federates recent (CNPG) and historical (Delta) data. DuckDB serves
  long-range/raw/backfill/analytical reads; it is not the high-QPS dashboard
  server — that stays CNPG rollups.
- **SRQL gets a metrics backend abstraction** at the existing parse -> AST ->
  QueryPlan -> per-entity codegen seam. Metric entities select CNPG vs
  DuckDB-over-Delta by window; everything else stays on CNPG. Emitting
  DuckDB-compatible SQL for the long-range path lets DuckDB own the federation,
  so SRQL grows one backend, not two.
- **Partition for pruning:** tenant / source / time bucket / `hash(series)`.
  Batch flush sized to avoid small-file explosion; a maintenance job compacts.
- **Tiering, not replacement.** Recent raw stays in CNPG for live graphing; Delta
  holds the long tail. The boundary is a retention window, tunable per tenant.
- **Measurement gates the scope.** If the corrected per-tenant raw rate fits CNPG
  + CAGGs, scope Delta to long-retention only; if not, Delta also serves raw
  history. Decided from task 2 numbers.

## Interaction with edge reduction
This change is sized assuming `move-anomaly-detection-to-edge` lands: the edge
emits verdicts and rollups, so anomaly no longer fans the raw stream out
centrally, and the raw rate the Delta writer and CNPG window must absorb is the
post-reduction rate. The two changes are complementary — edge reduction shrinks
the volume; tiering decides where the surviving volume lives.

## Risks / Trade-offs
- **Two query backends to keep correct.** Mitigation: SRQL routing tests + a
  round-trip parity test; DuckDB owns the federation so the SRQL surface stays
  single.
- **Small-file / compaction overhead** in Delta. Mitigation: batch sizing +
  scheduled compaction; benchmark file counts at the measured rate.
- **DuckDB single-node scan limits** for very large raw ranges. Mitigation:
  partition pruning + Delta stats skipping; push high-QPS to CNPG rollups.
- **Operational surface** (object store, Delta maintenance, DuckDB workers) per
  tenant. Mitigation: per-tenant prefix + a templated maintenance job; the
  instance-per-tenant model already implies per-tenant operational units.
- **Premature build.** Mitigation: the task-2 decision gate can scope Delta to
  long-retention only (or defer it) if the measured rate fits CNPG.
