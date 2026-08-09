# 50k-Agent Sizing Notes

## Captured Fixture Shape

Command:

```bash
cd elixir/serviceradar_core
MIX_ENV=test mix run --no-start bench/metric_fixture_profile.exs
```

Inputs:
- Fixture directory: `tmp/metric-fixtures/demo-smoke-cli`
- Fixture count: 10 captured `serviceradar.metric.v1.MetricBatch` payloads
- Observed demo metrics stream rate: 0.683 messages/second
- Current fleet assumption for first-pass projection: 13 agents
- Target: 50,000 agents
- Durable consumer fanout assumption: 3 consumers (persistence, anomaly, capacity)

Measured fixture shape:
- Payload bytes: 3,504,891
- Metric points: 22,650
- Metrics: 1,372
- Average bytes/message: 350,489.1
- Average points/message: 2,265.0
- Average bytes/point: 154.741
- Average points/metric: 16.509

Observed demo model:
- Messages/sec: 0.683
- Points/sec: 1,546.995
- DB rows/sec: 1,546.995
- Stream ingress: 0.228 MiB/sec
- Consumer fanout at 3 durable consumers: 0.685 MiB/sec

Linear 50k-agent projection from the 13-agent assumption:
- Scale factor: 3,846.154
- Messages/sec: 2,626.923
- Points/sec: 5,949,980.769
- DB rows/sec: 5,949,980.769
- Stream ingress: 878.055 MiB/sec
- Consumer fanout at 3 durable consumers: 2,634.166 MiB/sec

Nearer-term 2,500-agent projection from the same 13-agent assumption:
- Scale factor: 192.308
- Messages/sec: 131.346
- Points/sec: 297,499.038
- DB rows/sec: 297,499.038
- Stream ingress: 43.903 MiB/sec
- Consumer fanout at 3 durable consumers: 131.708 MiB/sec

## Interpretation

This projection is intentionally blunt. It says that if the current captured
payload shape and current per-agent emission rate scale linearly, the target is
not a "tune one Broadway pipeline" problem. It becomes a partitioning and write
path problem:

- A single EventWriter pipeline is not a credible 50k-agent target.
- Push consumers with large ack windows are the wrong delivery primitive.
- CNPG persistence must be measured as a bulk ingest system, not inferred from
decode or row-construction speed.
- Anomaly/capacity state must have deterministic partition ownership. Generic
active-active consumers over the same metric stream can split per-series state.

The 50k model is useful as a stress target, but it is not the current product
delivery gate. With the live demo fleet around 13 agents and a possible
nearer-term customer closer to 2,500 agents, the practical path is to make the
existing JetStream/EventWriter/CNPG system correct, observable, and less wasteful
before committing to a new storage/streaming architecture.

Local BEAM benchmarks still matter because they bound the current decode and
row-build path. Current fixture replay shows decode/row/extract can reach
hundreds of thousands of points/second locally after removing the
`series_identity_hint` log storm, but the 50k projection is several million
points/second before database writes and durable consumer fanout.

## Local Pull/Buffering Benchmark

Command:

```bash
cd elixir/serviceradar_core
EVENT_WRITER_BUFFER_BENCH_MESSAGES=100000 \
  EVENT_WRITER_BUFFER_BENCH_PAYLOAD_BYTES=1024 \
  MIX_ENV=test \
  mix run --no-start bench/event_writer_pull_buffering.exs
```

Small smoke result from this branch:

- Mode: `buffer_drain`
- Messages: 1,000
- Payload bytes/message: 512
- Elapsed: about 7 ms
- Messages/sec: about 135k
- Local pending after drain: 0
- Overflow drops: 0

This benchmark is not a replacement for live JetStream/CNPG measurement. It
proves the pure producer queue/drain path stays bounded and is not the first
obvious bottleneck for demo-sized message counts. The real throughput gate is
still decode/row expansion plus database writes.

## Runtime Signals Added

The branch exposes these operator-facing metrics through Telemetry.Metrics:

- EventWriter pull requests, producer queue depth, in-flight pulls, overflow
  drops, ack duration, batch duration, durable pending/ack-pending/redelivery
  counts, and retention-risk level.
- Anomaly sample extractor accepted sample count, total drops, process drops,
  unidentified-sysmon drops, and accepted metric-class count.
- Capacity forecasting source evaluations by source/metric/status/skip reason,
  including rows considered and usable sample count.

These signals are intentionally low-cardinality. They answer whether the system
is keeping up, where samples are being dropped, and why capacity forecasts are
skipped without creating one telemetry series per device or process.

## Golden Path Candidate

Use JetStream as the durable log and NATS KV as the lease/assignment registry;
do not build a separate Raft system unless JetStream/KV semantics prove
insufficient.

Recommended shape:

- Producers or gateways publish metrics into explicit partitions, for example
  `metrics.pNN.<source>...`, where `NN = hash(attested_series_identity) mod N`.
- Each processing concern has one pull durable per partition or one durable
  filtered to a bounded partition group:
  - persistence partition durable
  - anomaly partition durable
  - capacity partition durable
- Workers acquire partition leases in a NATS KV bucket using CAS/expected
  revision and TTL.
- Only the lease holder pulls that partition's durable consumer.
- Checkpoints are per partition and/or per series within the partition.
- On worker death, the lease expires; another worker resumes pulling from the
  same durable consumer and loads the partition checkpoint.
- Scaling horizontally means increasing partition count and assigning more
  partitions to more workers, not letting every worker consume every series.

This avoids a custom consensus layer for the first production design because:

- JetStream is the replay log.
- Durable consumer ack floors are the stream checkpoints.
- KV CAS/TTL provides practical partition leasing.
- Per-partition checkpoints provide anomaly/capacity restart state.

KV by itself is not enough. It must be tied to the data path. If workers only
advertise ownership in KV while sharing one broad durable consumer, state can
still split. The worker that owns a partition must be the only worker pulling
that partition's durable.

## CNPG Bulk Write Direction

The current metrics processor already performs bulk insert at the EventWriter
batch boundary:

- `ServiceRadar.EventWriter.Processors.Metrics.process_batch/1`
- `ServiceRadar.EventWriter.Processors.Telemetry.insert_rows/1`
- `ServiceRadar.EventWriter.BulkInsert.insert_all/3`

That path uses chunked `Repo.insert_all` with `on_conflict: :nothing`. It avoids
one insert per row, but it is still multi-row INSERT through Ecto with many
columns, JSONB fields, indexes, and a Timescale hypertable primary key.

For the 50k-agent target, the next benchmark must compare:

- current `Repo.insert_all` into `timeseries_metrics`
- staged table plus `INSERT INTO ... SELECT ...`
- PostgreSQL `COPY` or Postgrex copy protocol into staging/final table
- partitioned workers writing independent time/series partitions
- any required rollup/downsample path that reduces raw row pressure

Until those DB write numbers exist, the honest answer is that the current code
has not proven it can handle 50k agents.

First live-CNPG benchmark:

```bash
cd elixir/serviceradar_core
DATABASE_URL='postgres://serviceradar:...@10.0.2.12:30455/serviceradar' \
  CNPG_SSL_MODE=require \
  METRIC_INSERT_ROLLBACK=true \
  MIX_ENV=dev \
  mix run --no-start bench/metric_fixture_cnpg_insert.exs
```

Result against `demo` CNPG through the reachable NodePort:

- Rows: 22,650
- Strategy: current `BulkInsert.insert_all`
- Transaction rollback: true
- Elapsed: 3,614.060 ms
- Throughput: 6,267.190 rows/sec

This benchmark writes through the real `platform.timeseries_metrics` hypertable
and indexes, then rolls the transaction back. It is not a full saturation test,
but it is already two to three orders of magnitude below the 50k-agent linear
projection of about 5.95M rows/sec. The current DB write path is therefore a
proven bottleneck candidate, not just a suspected one.

First live-CNPG COPY control:

```bash
cd elixir/serviceradar_core
DATABASE_URL='postgres://serviceradar:...@10.0.2.12:30455/serviceradar' \
  CNPG_SSL_MODE=require \
  METRIC_INSERT_STRATEGY=copy_csv \
  METRIC_INSERT_ROLLBACK=true \
  MIX_ENV=dev \
  mix run --no-start bench/metric_fixture_cnpg_insert.exs
```

Result against the same `demo` CNPG route and same captured rows:

- Rows: 22,650
- Strategy: Postgrex `COPY ... FROM STDIN WITH (FORMAT csv)` into
  `platform.timeseries_metrics`
- Transaction rollback: true
- Elapsed: 1,150.014 ms
- Throughput: 19,695.405 rows/sec

COPY is about 3.1x faster than the current `insert_all` path for this fixture,
but it is still about 302x below the single-path 50k-agent projection. That
means "use COPY" is not a complete answer. The golden path still needs
deterministic horizontal partitions, per-partition durable ownership, and likely
producer-side reduction/rollups if the raw row rate remains near the linear
projection.

First live-CNPG parallel COPY control:

```bash
cd elixir/serviceradar_core
DATABASE_URL='postgres://serviceradar:...@10.0.2.12:30455/serviceradar' \
  CNPG_SSL_MODE=require \
  METRIC_INSERT_STRATEGY=copy_csv \
  METRIC_INSERT_PARALLELISM=4 \
  METRIC_FIXTURE_PROFILE_REPEAT=2 \
  METRIC_INSERT_ROLLBACK=true \
  MIX_ENV=dev \
  mix run --no-start bench/metric_fixture_cnpg_insert.exs
```

Results against the same route:

- Single worker, 45,300 rows: 4,114.933 ms, 11,008.685 rows/sec
- Four workers, 45,300 rows: 2,867.782 ms, 15,796.180 rows/sec
- Observed parallel gain: about 1.43x from four workers

A small 22,650-row pass was even less favorable to parallelism: two workers
reported 7,896.160 rows/sec, four workers reported 11,406.201 rows/sec, and a
single worker rerun reported 13,021.375 rows/sec. The early signal is that
client-side parallel COPY alone does not provide linear scaling into the current
hypertable/index path. It may still be useful as part of deterministic
partitioning, but the DB-side partition/index/write-amplification plan has to be
measured explicitly.

First live-CNPG staged COPY control:

```bash
cd elixir/serviceradar_core
DATABASE_URL='postgres://serviceradar:...@10.0.2.12:30455/serviceradar' \
  CNPG_SSL_MODE=require \
  METRIC_INSERT_STRATEGY=copy_stage_insert \
  METRIC_FIXTURE_PROFILE_REPEAT=2 \
  METRIC_INSERT_ROLLBACK=true \
  MIX_ENV=dev \
  mix run --no-start bench/metric_fixture_cnpg_insert.exs
```

The staged path creates a temporary heap table with the same columns and no
indexes, copies the captured rows into it, then optionally inserts from staging
into `platform.timeseries_metrics`.

Results against the same route:

- `copy_stage`, 22,650 rows: 2,322.379 ms, 9,752.932 rows/sec
- `copy_stage_insert`, 22,650 rows: 2,774.808 ms, 8,162.728 rows/sec
- `copy_stage_insert`, 45,300 rows: 4,712.806 ms, 9,612.108 rows/sec
  - stage COPY phase: 3,546.690 ms, 12,772.473 rows/sec
  - final insert phase: 1,166.113 ms, 38,847.004 rows/sec
- `copy_stage_insert`, 45,300 rows, four workers: 3,444.861 ms,
  13,150.022 rows/sec
- Same-load direct `copy_csv`, 45,300 rows: 3,324.497 ms,
  13,626.122 rows/sec

This staged-table control does not rescue the current CNPG/Timescale path. The
final insert from staging is not the only problem; raw staging COPY over this
route is itself only in the low tens of thousands of rows/sec. Four staged
workers roughly match, but do not materially exceed, a single direct COPY run.
That keeps CNPG as a bottleneck candidate and makes the remaining database proof
gap narrower: only real database partitioning, schema/index reduction, hardware
changes, or raw row reduction can plausibly close the several-hundred-times gap.

Production-like schema check against `demo` CNPG on 2026-06-17:

- Database extensions: TimescaleDB 2.24.0 and PostGIS 3.6.2.
- `platform.timeseries_metrics` is a Timescale hypertable owned by
  `serviceradar`, with one time dimension on `timestamp`.
- Chunk interval: 7 days; active chunk count during the check: 2, covering
  2026-06-04 through 2026-06-18 UTC.
- Compression was disabled for the active hypertable.
- Write-path indexes present during the benchmark:
  - `timeseries_metrics_pkey` unique btree on
    `(timestamp, gateway_id, series_key)`
  - `idx_timeseries_metrics_device` partial btree on `device_id`
  - `idx_timeseries_metrics_device_if_metric_time` btree on
    `(device_id, if_index, metric_name, metric_type, timestamp DESC)`
  - `idx_timeseries_metrics_name` btree on `metric_name`
  - `idx_timeseries_metrics_timestamp` btree on `timestamp DESC`
  - `timeseries_metrics_timestamp_idx` btree on `timestamp DESC`

So the live `insert_all`, direct COPY, parallel COPY, and staged-COPY controls
above did exercise the real demo hypertable and current production-like index
shape, not a synthetic minimally indexed target. That is enough to reject the
current single-hypertable/index path as a 50k-agent raw-row design. It is not
enough to reject CNPG/Timescale as a product storage component: actual database
partitioning, reduced indexes, compression/rollups, hardware isolation, and raw
row reduction still need a separate sizing pass before selecting a different
metrics store.

## CNPG Decision Gate

Current evidence says CNPG is a bottleneck candidate, not the only bottleneck
and not yet a proven dead end.

Before selecting a different database, maximize and measure the current
Timescale/CNPG path under production-like conditions:

- Use `COPY` or large multi-row inserts through explicit batches of 10k+ rows.
- Keep PgBouncer/connection pooling in the path and verify pool saturation does
  not serialize ingestion.
- Tune chunk intervals so active chunks stay memory-resident under the measured
  row rate. For this workload, validate smaller high-volume intervals such as
  one to six hours and record resulting chunk row counts.
- Review write-path indexes and JSONB/tag indexes on
  `platform.timeseries_metrics`; benchmark minimally indexed staging before
  final hypertable insert.
- Enable compression on older chunks and continuous aggregates/rollups for UI
  and SRQL queries that do not need raw points.
- Measure WAL generation, disk I/O, CPU, locks, autovacuum, chunk stats, and
  checkpoint pressure during ingest tests.
- Verify storage and scheduling assumptions: NVMe/local PVs where appropriate,
  dedicated DB node affinity, enough cores/RAM for active chunks and WAL.
- Run parallel writers against actual database partitions, not only concurrent
  clients writing one hot hypertable/index path.

The decision should be:

- If minimally indexed staged COPY plus partitioned `INSERT INTO ... SELECT`
  cannot get within an order of magnitude of the required raw row rate on
  production-like hardware, CNPG/Timescale should not be the raw high-rate
  metrics store for the 50k-agent target.
- If staged/partitioned writes are viable but the current hypertable path is not,
  keep CNPG for metadata, rollups, and queryable timeseries while changing the
  write path and schema/index strategy.
- If raw row volume remains near the linear projection, add producer-side
  aggregation/downsampling or a tiered store before changing databases. A faster
  database does not remove the NATS ingress/fanout and anomaly/capacity compute
  load created by persisting every point.
- If the target remains about 6M raw rows/sec, expect sharding across multiple
  database instances or offloading the hottest raw metric path; a single tuned
  CNPG/Timescale primary is not a credible default assumption.

Candidate alternatives should be evaluated only against the same captured
protobuf fixture and the same projected shape: raw row ingest, retention,
query patterns needed by SRQL/UI, anomaly/capacity replay, and operational
complexity. Otherwise we risk replacing a measured bottleneck with an unmeasured
distributed storage problem.

TDengine is the current preferred future raw-store control candidate if the
near-term JetStream/EventWriter/CNPG repair path still cannot meet practical
scale targets. Its native design is closer to the ServiceRadar requirement than
a single-primary PostgreSQL hypertable path: distributed TSDB storage,
Raft-backed high availability, schemaless line-protocol ingestion, and built-in
stream processing/rollup primitives. Those properties make it worth benchmarking
before more general columnar OLAP stores. They do not prove it will satisfy the
ServiceRadar workload, and they do not make it the current implementation
priority.

Vendor or generic TSBS benchmarks are useful context but not acceptance evidence
for ServiceRadar. TDengine must be tested with ServiceRadar's captured
protobuf-expanded rows, cardinality, SRQL/UI query shapes, and anomaly/capacity
replay expectations. The product decision is not "which TSDB has the best
published benchmark"; it is "which storage architecture can absorb this specific
metrics stream while preserving the query and replay semantics users need."

## Rust Protobuf Control Harness

This branch adds a standalone Rust control binary for the current
`serviceradar.metric.v1.MetricBatch` payload shape:

```bash
METRIC_BENCH_FIXTURE_DIR=tmp/metric-fixtures/demo-smoke-cli \
  # harness removed 2026-08-07 with rust/metrics-delta-writer; recover from git history:
  #   git show 4f198c0831:rust/metrics-delta-writer/src/bin/metrics_protobuf_bench.rs
  sfw cargo run -p serviceradar-metrics-delta-writer --bin metrics-protobuf-bench
```

It lived under `rust/metrics-delta-writer` and reused the same
`serviceradar-metric-proto` bindings and `batch_to_rows/2` flattening path as
the Delta writer skeleton.

**The harness was removed on 2026-08-07** together with that crate: the Delta
lakehouse design it belonged to was superseded by tiered cold storage
(`add-tiered-telemetry-offload`), the writer never advanced past a no-op
`LoggingSink`, and this change's benchmark work is complete (task 3.9). The
measurements below are the durable output and remain valid; the harness is
recoverable from git history if a re-run is ever needed. It reports separate phase timing for:

- reading captured payload files;
- protobuf decode plus row transform;
- a deterministic Welford anomaly-hook loop over row series;
- a deterministic capacity-hook aggregation loop;
- optional batched PostgreSQL writes into a temporary table.

PostgreSQL writes are off by default so the control can be run safely against
captured fixtures. To include the DB write phase, point it at disposable local
CNPG, a benchmark schema, or an explicit test window:

```bash
METRIC_BENCH_FIXTURE_DIR=tmp/metric-fixtures/demo-smoke-cli \
METRIC_BENCH_PG_DSN='postgres://serviceradar:...@localhost:5455/serviceradar' \
METRIC_BENCH_BATCH_ROWS=5000 \
  # harness removed 2026-08-07 with rust/metrics-delta-writer; recover from git history:
  #   git show 4f198c0831:rust/metrics-delta-writer/src/bin/metrics_protobuf_bench.rs
  sfw cargo run -p serviceradar-metrics-delta-writer --bin metrics-protobuf-bench
```

The write phase creates and truncates a session-local temporary table named
`sr_metric_bench_points`; it does not write `platform.timeseries_metrics` and
therefore does not replace the Elixir CNPG benchmark that exercises the real
hypertable/index path. Its purpose is an upper-bound control for Rust protobuf
decode/transform/hook/write overhead, not a production replacement for
EventWriter.

## Implementation Control Comparison

Current controls now cover three shapes:

- **Optimized BEAM/ERTS core-elx**: implemented production path for this change.
  It uses pull JetStream consumers, bounded producer buffering, low-cardinality
  hot-path telemetry, EventWriter decode/row benchmarks, and live CNPG
  `insert_all`/COPY/staged-COPY measurements against captured payload rows.
- **Standalone Rust control**: `metrics-protobuf-bench` provides an upper-bound
  decode/transform/anomaly-hook/capacity-hook/temp-table-write harness over the
  same canonical protobuf payloads. It is benchmark evidence only; it carries no
  distributed state ownership, replay, alerting, or rollout semantics.
- **Go db-event-writer control**: the historical Go writer is not a valid direct
  comparison until it is rebuilt against the current protobuf `MetricBatch`
  shape, row expansion, anomaly/capacity hook points, and CNPG schema. Treat it
  as future benchmark work, not proof that the present pipeline should move out
  of BEAM.

This comparison keeps the production decision with the BEAM/ERTS EventWriter
repair in this change. If Rust or Go controls demonstrate an order-of-magnitude
advantage that the BEAM path cannot close, the next step is a separate OpenSpec
for partition ownership, failover, replay, and migration semantics rather than a
silent rewrite of the live metrics consumer.

## Proof Gaps

Evidence still required before claiming the current architecture works:

- Repeat/saturation CNPG rows/sec for current `Repo.insert_all` using larger
  captured-row repeats and controlled database load.
- Repeat/saturation CNPG rows/sec for COPY/staged ingest on production-like
  hardware and controlled database load. The current demo pass used the real
  production-like hypertable/index shape, but not production hardware isolation.
- Parallel COPY/write-path scaling across database partitions, not only
  concurrent clients writing the current hypertable/index path.
- Alternative metrics-store control benchmark, if staged CNPG cannot meet the
  required order of magnitude.
- Live stream lag telemetry for anomaly and capacity consumers independent of
  EventWriter persistence lag.
- Anomaly/capacity partition ownership tests, including crash/restart replay.
- A rebuilt Go control benchmark for decode/transform/write upper bounds if a
  future proposal needs to compare a non-BEAM production rewrite. The Rust
  control exists in `metrics-protobuf-bench`.
