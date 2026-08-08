# Change: Add complementary Rust analytics lanes

## Status
Exploratory and parked. This proposal captures future benchmark lanes for
TDengine, Iggy, and Iceberg, but it is not the current implementation priority.
The near-term priority is to make the existing JetStream/EventWriter/CNPG path
correct and stable for the current demo fleet, then size pragmatic improvements
toward a possible 2,500-agent customer.

## Why
The measured CNPG path is hundreds of times short of the projected 50k-agent raw
metric row rate. Pull consumers fix backpressure, but they do not create storage
throughput or remove BEAM allocation from the anomaly/capacity hot path.

TDengine and Iggy are worth adding as complementary benchmark/analytics lanes,
not immediate replacements for NATS JetStream or CNPG/Timescale. ServiceRadar
should evaluate them through a Rust-native service and SRQL backend, not through
an Elixir TDengine client or a REST write adapter.

## What Changes
- Introduce a Rust `serviceradar-analytics` service that can consume metrics
  from the existing JetStream path and optionally mirror/replay them into
  complementary stores.
- Benchmark the raw metrics stream substrate itself. NATS JetStream remains the
  control-plane/default substrate; Iggy MAY be evaluated as a complementary raw
  metric stream for non-critical metrics even before clustering/failover lands.
- Persist raw high-rate metric points into TDengine through a trusted native or
  WebSocket-capable Rust path, selected by benchmark and operational review, or
  select an Iceberg-backed raw lakehouse tier if the benchmark proves that a
  TSDB serving store is unnecessary for the raw path.
- Keep all production metrics flowing through NATS JetStream first during this
  change. The Rust service is initially a JetStream consumer/mirror, not a
  collector-side database bypass.
- Move anomaly/capacity evaluation out of the BEAM hot path while preserving the
  DeepCausality reasoner as the source of truth for rolling anomaly decisions.
- Use JetStream durable consumers and NATS KV partition leases for horizontal
  ownership; do not build a custom Raft layer unless JetStream/KV semantics
  prove insufficient.
- Extend the Rust SRQL engine with a TDengine-backed metrics query backend for
  raw metrics and rollups while preserving CNPG-backed entities.
- Evaluate an Iggy-to-Iceberg raw sink as a separate benchmark lane for
  long-retention raw metrics, replay, and offline analytics.
- Keep CNPG for metadata, relational state, findings/events, rollups that still
  belong in PostgreSQL, and compatibility during migration.
- Add a benchmark gate based on captured ServiceRadar protobuf metric fixtures,
  not vendor TSBS numbers.

## Non-Goals
- No Elixir TDengine client library in the hot path.
- No TDengine REST write adapter for the benchmark or production design.
- No collector, agent, or gateway direct-to-database writes.
- No replacement of NATS JetStream or all CNPG/Timescale storage in this change.
- No assumption that Iceberg alone can serve low-latency UI/SRQL metric queries
  until query and compaction benchmarks prove it.
- No hand-rolled rolling anomaly detector separate from DeepCausality.
- No replacement of NATS KV/control-plane coordination unless a separate
  proposal proves an equivalent lease/checkpoint/control store.
- No replacement of NATS JetStream/KV for distributed leases, stream ownership,
  credentials, and control coordination.

## Impact
- Affected specs: `metrics-analytics`, `srql`, `observability-signals`
- Affected code: `rust/` service crates, `rust/srql`, Helm chart values,
  container images, OpenSpec runbooks, metric benchmark fixtures
- Runtime impact: adds opt-in Rust analytics lanes that mirror/replay metrics to
  TDengine/Iggy/Iceberg candidates while keeping the existing JetStream and
  CNPG/Timescale paths available during evaluation
