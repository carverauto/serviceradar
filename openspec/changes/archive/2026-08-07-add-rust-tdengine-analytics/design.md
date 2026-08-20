## Context
The current EventWriter path decodes protobuf metric envelopes in Elixir, expands
them to `platform.timeseries_metrics` rows, and writes to CNPG/Timescale. Live
demo benchmarks using captured ServiceRadar metric fixtures measured:

- current `Repo.insert_all`: about 6.3k rows/sec
- direct PostgreSQL `COPY`: about 11.9k to 19.7k rows/sec
- staged temp-table plus final insert: about 8.2k to 13.2k rows/sec

The same fixture projects to about 5.95M raw metric rows/sec at 50k agents under
the current linear model. CNPG may still be valid for metadata, findings, and
lower-rate relational data, but the raw metrics path needs a different control
benchmark.

This proposal is intentionally parked after the initial sizing discussion. With
zero external production customers and a current demo fleet of about 13 agents,
the immediate product need is not a storage-plane rewrite. The current
implementation should first be made correct and observable, then benchmarked
against a nearer-term 2,500-agent target.

A 2,500-agent linear projection from the same fixture is roughly:

- 131 metric messages/sec
- 297k raw metric points/sec
- 44 MiB/sec raw stream ingress
- 132 MiB/sec aggregate fanout with three durable consumers

That target may be reachable through batching, cardinality/row reduction,
rollups, tuned CNPG writes, and fewer live consumers. It does not justify making
TDengine/Iggy/Iceberg the current blocking path.

TDengine is the preferred serving-store candidate because its native shape
aligns with the ServiceRadar raw metrics problem: distributed TSDB storage,
high-cardinality device/tag modelling, HA modes, stream processing, and
Kubernetes deployment. Iggy is a complementary raw-stream candidate. Its current
clustering/failover maturity is a known risk, but metrics are not yet the most
mission-critical ServiceRadar stream, so Iggy can still be useful as an
experimental/non-critical metrics lane. All benchmarks must use ServiceRadar's
captured protobuf-expanded metrics, not generic TSBS payloads.

## Goals
- Preserve future option value for complementary Rust analytics lanes for
  TDengine, Iggy, and optionally Iceberg without replacing NATS JetStream or
  CNPG/Timescale in the current work.
- Prove or reject TDengine for ServiceRadar raw metrics using captured
  `MetricBatch` fixtures and live JetStream replay/mirroring.
- Keep the experimental high-rate path in Rust, using native/WebSocket-capable
  TDengine access. Do not put an Elixir TDengine client in the production path.
- Preserve the architectural rule that production metrics land on JetStream
  before any database write during this change.
- Keep DeepCausality as the anomaly reasoner implementation.
- Make horizontal scaling deterministic with partition leases rather than
  active-active workers splitting per-series state.
- Add SRQL support for querying TDengine-backed metric entities while retaining
  CNPG-backed entities.

## Non-Goals
- Selecting TDengine before benchmark evidence.
- Replacing NATS JetStream or all CNPG usage.
- Adding custom consensus or Raft.
- Writing metrics from agents/gateways directly into TDengine.
- Preserving every existing CNPG raw metric table/index as the long-term query
  shape if TDengine wins.
- Replacing NATS JetStream/KV for distributed leases, stream ownership,
  credentials, or control coordination.

## Architecture

### Serving store versus raw lakehouse
TDengine and Iceberg solve different parts of the problem.

TDengine is a candidate for the hot serving store: recent raw metrics, latest
queries, time-window graphs, bucketed aggregates, and anomaly/capacity replay
with low operational latency.

Iceberg is a candidate for the raw historical lakehouse: cheap long-retention
storage, replay, offline analytics, model training, cross-tenant reporting, and
large scans through engines such as DataFusion, Spark, Flink, Trino, or Dremio.
It is not automatically a replacement for the serving store because streaming
Iceberg writes introduce file sizing, commit, manifest, snapshot, and compaction
work. If those maintenance loops lag, query planning and scan latency can
degrade even when object storage itself is cheap.

The benchmark matrix should therefore include three shapes:

- TDengine hot serving store only, with retention/downsampling policies.
- Iggy raw stream plus Iceberg raw sink, with SRQL serving queries still backed
  by TDengine or CNPG rollups.
- Iggy raw stream plus Iceberg-only metrics backend, accepted only if latest,
  last-hour, bucketed, and replay queries meet latency targets after compaction
  and metadata maintenance are included.

The default recommendation is tiered:

- NATS for control/leases/lower-rate platform streams.
- JetStream or Iggy for raw metric transport, selected by benchmark.
- TDengine or equivalent TSDB for hot metric serving if low-latency SRQL/UI
  queries require it.
- Iceberg for raw long-term history and offline replay if write/compaction costs
  are acceptable.

An Iceberg-only design is attractive if raw retention dominates and the product
can tolerate query latency through an OLAP engine. It is risky if customers
expect the device page, dashboard cards, anomaly replay, and capacity planner to
read fresh recent data with tight latency and minimal moving parts.

### Stream substrate
NATS JetStream is not proven to be the current bottleneck. The 50k-agent model
is only about 2,627 metric messages/sec because producers already batch thousands
of points per message. The scary number is byte volume:

- about 878 MiB/sec persisted stream ingress for raw metrics
- about 2.6 GiB/sec aggregate fanout with three durable consumers

That means generic "messages/sec" comparisons are misleading. The benchmark must
measure payload size, persistence, replication, consumer fanout, ack cadence,
replay, and tail latency using ServiceRadar metric envelopes.

NATS remains the default control substrate because JetStream provides durable
replay, consumers, KV, object storage, security, and operational integration in
one system. Iggy is a credible complementary raw-stream candidate because it is
a Rust-native persistent streaming platform with partitioning, consumer groups,
and published high-throughput claims. Its current clustering/failover maturity
is a known risk, but acceptable for an opt-in non-critical metrics lane. It does
not replace NATS KV for leases and control state in this design unless a later
proposal proves an equivalent coordination mechanism.

The first acceptable Iggy shape is therefore complementary/hybrid:

- NATS JetStream/KV remains for control streams, leases, credentials, object
  store usage, and lower-rate platform events.
- Production metric sources continue to publish to JetStream first.
- A Rust mirror/replay path MAY write the same metric envelopes to Iggy for
  benchmarking and optional downstream analytics.
- Iggy MAY carry a non-critical raw high-volume metric stream while NATS
  JetStream/KV continues to provide distributed leases and control coordination.
- Iggy SHOULD NOT carry the only copy of mission-critical telemetry until
  clustering, failover, durability, replay, and operational recovery are proven.
- The Rust analytics service abstracts the metric stream source so JetStream and
  Iggy can be benchmarked with the same decode/write/evaluate path.
- If Iggy wins the raw stream benchmark, partition ownership still needs a
  durable coordination source. NATS KV is acceptable for that control plane even
  when raw bytes flow through Iggy.

The decision gate is not "Iggy can publish 1M small messages/sec." It is whether
Iggy can carry ServiceRadar's 350 KB-class metric envelopes, or a redesigned
smaller envelope, with persistence, replay, consumer groups, TLS/auth, clustering
or acceptable non-critical failure-domain behavior, and operational recovery
better than JetStream under the same conditions.

### Rust analytics service
Add a Rust service, tentatively `serviceradar-analytics`, that initially
consumes metric JetStream subjects with pull durables and can mirror/replay those
metrics to complementary analytics stores. The service owns:

- protobuf `MetricBatch` decode using `serviceradar-metric-proto`
- deterministic partition assignment from series identity
- raw metric writes to TDengine or an experimental lakehouse sink
- rolling anomaly evaluation through DeepCausality-backed logic
- capacity forecast input preparation and result emission
- low-cardinality telemetry for lag, decode, evaluation, write latency, and
  dropped/failing samples

The first implementation should reuse patterns from `rust/causal-engine` where
practical: Tokio runtime, config loading, tracing, and metric proto bindings.
It may become a successor to `causal-engine`, but the first slice should prove
the metric hot path before absorbing every causal/zen feature.

### Partition ownership
Use JetStream as the replay log and NATS KV as the assignment registry for the
default implementation:

- Producers or gateways publish to partitionable metric subjects, or the
  analytics service maps broad subjects to partition durables.
- Each partition has one durable per concern or one durable per bounded
  partition group.
- Workers acquire partition leases through KV CAS/TTL.
- Only the lease holder pulls that partition's durable.
- On worker death, the lease expires and another worker resumes from the same
  durable checkpoint.

This avoids custom consensus for the first design. KV ownership must be tied to
the data path; advertising ownership while multiple workers pull the same broad
durable is not acceptable.

If Iggy is selected for raw metric transport, the lease/ownership mechanism must
remain explicit. NATS KV can own leases while Iggy owns raw byte transport. Iggy
consumer groups alone are not enough if anomaly/capacity state requires
deterministic per-series ownership and restart checkpoints.

### TDengine write path
Do not use TDengine REST writes for production or primary benchmark evidence.
The benchmark should compare trusted Rust options, such as native/client-driver
binding or the supported WebSocket path, and select one based on throughput,
maintainability, TLS/auth support, and operational maturity.

The TDengine schema/supertable design must be explicit. The first candidate
should model stable identity dimensions as tags and numeric values as fields,
while preserving enough metadata for SRQL filters and anomaly/capacity replay.
Candidate tags include tenant/partition, agent, gateway, device UID, resource
identity, metric type, metric name, and interface index where applicable.

### Iceberg sink path
If evaluating Iceberg, the Rust analytics service or a dedicated Rust connector
SHALL write larger partition-aligned files rather than one small file per
microbatch. The design must include:

- partitioning by time and deterministic series/tenant dimensions;
- file sizing targets;
- commit cadence and exactly-once or idempotent commit strategy;
- compaction/rewrite schedule;
- snapshot expiration;
- manifest rewrite policy;
- query engine selection for SRQL and offline analytics;
- a clear freshness SLO for data becoming queryable.

Iggy connectors may be a useful starting point, but connector availability is not
the decision. The decision is whether the complete sink plus compaction plus
query engine can meet ServiceRadar's operational requirements.

### SRQL integration
Extend Rust SRQL with a metrics backend abstraction. CNPG remains the backend for
devices, logs, findings, relational inventory, and compatibility. TDengine or an
Iceberg query engine can become a metrics backend after benchmark approval.

SRQL must keep the same user-facing query contract for supported metric queries:
device/resource filters, time windows, metric type/name filters, latest queries,
bucketed aggregation, sorting, and limits.

### Migration
Run dual-write or replay-based comparison before any production cutover:

1. Replay captured metric fixtures into local TDengine.
2. Replay live demo JetStream metrics into TDengine without disabling CNPG.
3. Compare row counts, query results, anomaly/capacity outputs, and lag.
4. Gate TDengine-backed SRQL behind config.
5. Only then consider disabling raw CNPG metric writes.

## Risks
- TDengine Rust client maturity may be weaker than its database engine.
  Mitigation: make client path a benchmark criterion and reject untrusted paths.
- SRQL query parity may be more work than ingestion.
  Mitigation: build the backend boundary first and test high-value metric query
  shapes before migration.
- Partition leases can still split state if not tied to durable ownership.
  Mitigation: require one lease holder per pulled durable partition.
- TDengine may ingest fast but fail required query/replay semantics.
  Mitigation: benchmark query and replay behavior before selection.
- Moving anomaly/capacity out of BEAM reduces ERTS distribution benefits.
  Mitigation: use JetStream durable checkpoints, KV leases, and per-partition
  state snapshots for crash/restart ownership transfer.
