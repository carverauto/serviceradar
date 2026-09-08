# Change: Tier metrics storage with a Delta lakehouse and DuckDB query path

## Why
Even with per-customer isolation (each tenant gets a dedicated CNPG and NATS
instance, no shared super-cluster), a single CNPG/Timescale primary cannot absorb
a high-rate tenant's raw metric firehose. Measured single-primary write
throughput on the current hypertable path is ~6.3k rows/sec (`insert_all`) to
~19.7k rows/sec (COPY), with parallel/staged COPY plateauing in the low tens of
thousands. The row-store tax — per-row B-tree inserts, JSONB/tag indexes, WAL
amplification, MVCC/autovacuum — is structural, not a tuning gap.

The product is already aggregate-first: ~15 Timescale continuous aggregates
exist and SRQL already auto-routes metric queries with a window > 6h to hourly
CAGGs. Raw per-point access is only needed for short-window/"latest" graphing and
sub-6h drill-down. That means the central store's real job is **recent raw +
rollups + metadata**, and the high-volume raw history belongs in a store built
for append-only columnar scans, not in an OLTP primary.

This change tiers metrics storage:
- **Raw history → a Delta Lake lakehouse** (Parquet + Delta transaction log) on
  object storage, written in batches by a Rust writer (delta-rs), partitioned for
  pruning. Cheap, append-friendly, storage/compute-separated, and per-tenant by
  object-store prefix.
- **Recent raw + rollups + metadata/alerts → CNPG** (unchanged role, smaller raw
  retention window), so live graphing and high-QPS dashboards stay fast on the
  existing CAGG tier.
- **Query → DuckDB** as the analytical engine over Delta, federating with CNPG
  (DuckDB `delta` + `postgres` extensions) so a single long-range query can span
  the recent CNPG rows and the long-term Delta history. SRQL routes
  recent/aggregate queries to CNPG and long-range/raw queries to
  DuckDB-over-Delta.

This supersedes the raw-store lanes of the parked `add-rust-tdengine-analytics`
proposal: TDengine and Iggy are explicitly **not** pursued; Delta + DuckDB is the
chosen raw tier and query path.

## What Changes
- Add a **Rust Delta writer** that consumes the metrics JetStream durable and
  batch-writes raw points to a Delta table on object storage, partitioned by
  tenant / source / time / `hash(series)` for file pruning.
- Reduce CNPG raw retention to a **recent window** sized for live graphing and
  sub-6h drill-down; keep the existing CAGG rollup tier and all metadata, alerts,
  findings, and capacity forecasts in CNPG.
- Add a **DuckDB-backed query path** for long-range and raw metric queries,
  using the DuckDB `delta` extension over the lake and the `postgres` extension
  to federate recent CNPG rows in the same query.
- Add a **metrics backend abstraction to SRQL** at the existing per-entity
  codegen seam: metric entities route recent/aggregate windows to CNPG and
  long-range/raw windows to DuckDB-over-Delta; non-metric entities stay on CNPG
  unchanged. Query results remain SRQL-shaped regardless of tier.
- Add Delta **table maintenance** (compaction, manifest/snapshot expiry,
  retention) as a scheduled job, per tenant.
- Add a **decision-gate benchmark** that establishes the corrected per-agent
  steady-state row rate (post process-cap, post edge-rollup) and proves the Delta
  write path and the DuckDB read path meet it before any cutover.
- Keep a **dual-write/parity migration**: CNPG raw is never removed until the
  Delta path is proven at parity for the queries that depend on raw points.

## Impact
- Affected specs: observability-signals, srql, cnpg
- Affected code: new `rust/metrics-delta-writer` (delta-rs), `rust/srql`
  (metrics backend abstraction + DuckDB execution for long-range/raw entities),
  CNPG raw retention policy and chunk settings, web-ng/SRQL long-range metric
  query routing, object-store config per tenant, a Delta maintenance job
- Affected runtime: per-tenant object-store bucket/prefix; per-tenant DuckDB
  query worker (embedded or sidecar); the metrics JetStream durable gains a Delta
  writer consumer
- Supersedes: the TDengine/Iggy raw-store lanes of `add-rust-tdengine-analytics`
  (now not pursued); reuses its Iceberg/lakehouse thinking with Delta as the
  chosen format
- Depends on: `move-anomaly-detection-to-edge` (edge rollups reduce the raw rate
  this tier must absorb; the tiering is sized assuming edge reduction)
