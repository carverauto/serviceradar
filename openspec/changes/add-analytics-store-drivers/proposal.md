# Change: Optional analytics archive with fast Timescale reads

> **Withdrawn.** The pg_duckdb architecture is no longer being pursued. This
> branch preserves the implementation and independent fixes for selective reuse;
> it is not a candidate for merge or further rollout. See [handoff.md](handoff.md).
> Do not archive-apply this change or the superseded offload proposal.

GitHub: [carverauto/serviceradar#477](https://github.com/carverauto/serviceradar/issues/477)

## Why

Primary dashboards need predictable latency for recent telemetry. Reading many
small Parquet files from object storage adds request and planning costs even
when queries select concrete manifest keys. Keep recent reads on Timescale and
use pg_duckdb for historical exploration.

Long-term Parquet storage remains optional. OSS installations must work with
Timescale alone, without a bucket, object-store credentials, or an analytics
head. The hosted service enables hybrid storage in its deployment configuration.

## What Changes

- Keep `timescale` as the product, Helm, and Compose default.
- Add explicit `hybrid` mode for named analytics tables. EventWriter continuously
  writes each consumed batch to both Timescale and Parquet. This is a supported
  operating mode, not a temporary cutover flag.
- Use a configurable hot window, **30 days by default**. Queries wholly inside
  it run on Timescale. Queries reaching beyond it run entirely on pg_duckdb,
  where the continuous Parquet copy contains both older and recent samples.
- Preserve `pg_duckdb` as an explicit Parquet-only mode. Unselected tables stay
  on Timescale in every mode.
- Keep 30 days of compressed Timescale data and continuous aggregates active in hybrid mode.
  Retention must cover at least the read window. Configure archive expiry
  separately; an absent archive expiry does not authorize deleting history.
- Keep JetStream first and EventWriter as the single persistence owner. A second
  datastore does not introduce a second consumer or collector-to-database writes.
- Require a complete analytics backend only when archive reads or writes are
  enabled. Never silently switch stores on a query failure.

## Impact

Affected specs: analytics-store, srql, observability-signals, cnpg,
docker-compose-stack, kubernetes-network-policy.

Affected code: AnalyticsStore config/writer/query routing; SRQL planning and
cursors; Timescale retention and CAGG reconciliation; Helm and release runtime
configuration; operator documentation and recovery tooling.

The existing dedicated pg_duckdb image, manifest, concrete-file query path,
staging/verification/publishing, and storage adapters remain. pg_duckdb must not
be installed on the Timescale primary. Analytics files must not share the CNPG
backup bucket.

This revises the approved #477 design after query-path validation. The older
`add-tiered-telemetry-offload` change stays superseded and must not be
archive-applied. This design does not restore its FDW union or completeness
frontier. Compression (#478) remains independent. The immediate rollout scope
is the current metrics table; NetFlow and other deployments remain unchanged.
