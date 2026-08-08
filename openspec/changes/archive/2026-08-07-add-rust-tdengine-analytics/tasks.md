## 1. Benchmark Harness
- [ ] 1.1 Add a Rust fixture loader for captured `MetricBatch` protobuf files.
- [ ] 1.2 Expand fixture metrics into the candidate TDengine row/tag model.
- [ ] 1.3 Add JetStream raw stream benchmarks using captured ServiceRadar envelope sizes, replication, and durable fanout.
- [ ] 1.4 Add Iggy raw stream benchmarks using the same captured envelope sizes, persistence, partitions, and consumer groups.
- [ ] 1.5 Add an Iggy-to-Iceberg sink benchmark with partition-aligned file sizing and compaction included.
- [ ] 1.6 Add a TDengine local benchmark path using a trusted Rust native or WebSocket-capable client.
- [ ] 1.7 Record rows/sec, bytes/sec, CPU, memory, and write latency percentiles.
- [ ] 1.8 Add query benchmarks for latest, time-window, bucketed aggregation, device/resource filters, and replay scans.
- [ ] 1.9 Compare benchmark output against the CNPG fixture benchmark in `fix-eventwriter-backpressure-hotpath/sizing.md`.

## 2. Rust Analytics Service
- [ ] 2.1 Scaffold `rust/serviceradar-analytics` with Tokio, tracing, config, and Bazel/container targets.
- [ ] 2.2 Reuse `serviceradar-metric-proto` for protobuf decode.
- [ ] 2.3 Define a metric stream source trait with JetStream as the first implementation and Iggy as an optional benchmark implementation.
- [ ] 2.4 Implement JetStream pull durable consumption for metric subjects.
- [ ] 2.5 Implement JetStream-to-Iggy mirror/replay mode for benchmark-only use.
- [ ] 2.6 Document Iggy clustering/failover as a known risk and define acceptable non-critical metrics usage.
- [ ] 2.7 Implement deterministic series partitioning.
- [ ] 2.8 Implement NATS KV lease acquisition, renewal, release, and expiry takeover tests.
- [ ] 2.9 Implement TDengine writer batches with bounded retries and backpressure.
- [ ] 2.10 Emit low-cardinality service telemetry for lag, decode, evaluation, write latency, drops, and failures.

## 3. Anomaly And Capacity
- [ ] 3.1 Port or wrap the DeepCausality anomaly reasoner in the Rust service without changing detector semantics.
- [ ] 3.2 Add per-partition anomaly state snapshots and restore tests.
- [ ] 3.3 Emit sparse anomaly open/clear findings back through JetStream for existing CNPG finding ingestion.
- [ ] 3.4 Add capacity planner input extraction from TDengine-backed metric windows.
- [ ] 3.5 Emit capacity forecast outputs through existing observability/finding paths.

## 4. SRQL
- [ ] 4.1 Add a Rust SRQL backend boundary for metric entities.
- [ ] 4.2 Implement TDengine SQL generation for supported metric queries.
- [ ] 4.3 Prototype Iceberg-backed metric query generation through the selected query engine if Iceberg remains viable after sink benchmarks.
- [ ] 4.4 Keep CNPG SQL generation for non-metric entities.
- [ ] 4.5 Add parity tests for representative `in:timeseries_metrics` queries against CNPG fixture results.
- [ ] 4.6 Add config gating for TDengine-backed or Iceberg-backed metric SRQL.

## 5. Deployment And Migration
- [ ] 5.1 Add Helm values for optional `serviceradar-analytics` deployment and TDengine connection config.
- [ ] 5.2 Add demo-only replay/dual-write mode that does not disable CNPG writes.
- [ ] 5.3 Document rollback: disable analytics TDengine writes and return metric SRQL to CNPG.
- [ ] 5.4 Add GitOps demo notes for TDengine endpoint, credentials, and operational checks.
- [ ] 5.5 Run focused Rust `cargo fmt`, `cargo test`, and `cargo clippy` for touched crates.
- [ ] 5.6 Run `openspec validate add-rust-tdengine-analytics --strict`.
