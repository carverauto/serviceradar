## 1. Validation Baseline
- [x] 1.1 Add synthetic dataset coverage for CPU, memory, disk, and network anomaly detection.
- [x] 1.2 Add a scale benchmark that reports raw samples/sec and detector evaluations/sec.
- [x] 1.3 Add randomized equivalence tests comparing compact-stat evaluation against current window-list evaluation.

## 2. Evaluation Cadence
- [ ] 2.1 Add per-metric-class evaluation interval and aggregation-mode configuration.
- [ ] 2.2 Implement per-series slot aggregation with slot metadata and spike-preserving defaults.
- [ ] 2.3 Count sustained-anomaly confirmation over evaluation slots.
- [ ] 2.4 Carry metric `kind`, `temporality`, `unit`, resource identity, and point attributes through anomaly sample extraction.
- [ ] 2.5 Rate-compute monotonic cumulative counters before anomaly evaluation.

## 3. Hot Path State
- [ ] 3.1 Replace baseline-list rebuilds with bounded ring-buffer state and incremental stats.
- [ ] 3.2 Update the reasoner/NIF boundary to accept compact state, a native state resource, or batched evaluations.
- [ ] 3.3 Keep anomalous evaluation values out of the clean baseline ring.

## 4. High-Cardinality Runtime
- [ ] 4.1 Add shard-owned series state for high-cardinality metric streams.
- [ ] 4.2 Add backpressure and idle-series eviction for shard workers.
- [ ] 4.3 Preserve deterministic per-series ordering under replay and shard handoff.

## 5. Scale Proof
- [x] 5.1 Add a benchmark profile for 50k agents with hundreds of metric series each.
- [x] 5.2 Add a benchmark profile targeting approximately 1M detector evaluations/sec.
- [ ] 5.3 Add a pipeline benchmark that includes JetStream/Broadway decode, aggregation, evaluation, verdict emission, and checkpointing.
- [ ] 5.4 Document the measured capacity envelope and tuning knobs.

## 6. Unified Metric Pipeline (`fj #3788`)
- [ ] 6.1 Evolve `serviceradar.metric.v1` to schema version 2 with `resource`, `kind`, `temporality`, `is_monotonic`, `unit`, `points[]`, `ingress_id`, and gateway-attested ingest identity.
- [x] 6.2 Add first-class metric emit APIs to the Go and Rust Wasm SDKs; remove/disable legacy `Result.Metrics` metric ingestion shims instead of preserving a JSON compatibility path.
  - [x] External SDKs `/Users/mfreeman/src/serviceradar-sdk-go` and `/Users/mfreeman/src/serviceradar-sdk-rust` expose `emit_telemetry` helpers for base64-wrapped encoded `serviceradar.metric.v1.MetricBatch` payloads and no longer expose plugin-result metric fields/builders.
- [ ] 6.3 Add canonical metric emit builders for first-party agent collectors/checkers.
- [ ] 6.4 Add gateway/core schema validation and OCSF/metric mis-bucket guardrails.
- [ ] 6.5 Add `Nats-Msg-Id`/duplicate-window idempotency for the high-rate `metrics` stream before multi-point fan-out.
- [x] 6.6 Migrate sysmon, SNMP, ICMP, MTR, sweep, rperf, wasm plugin, and native add-on producers off status/check-result/plugin-result JSON metric smuggling.
  - [x] 6.6a Sysmon, SNMP, and ICMP emit `serviceradar.metric.v1.MetricBatch` payloads and publish through `metrics.*`.
  - [x] 6.6b Wasm plugin and native add-on metric producers emit encoded `MetricBatch` payloads through the telemetry SDK/bridge and publish through `metrics.*`.
  - [x] 6.6c MTR emits canonical `MetricBatch` payloads for scalar availability/hop/loss/latency/jitter series through `mtr-metrics`; trace/hop domain result chunks remain separate for `MtrMetricsIngestor`.
  - [x] 6.6d Sweep emits canonical `MetricBatch` payloads for aggregate host counts, host/port availability, latency/loss, scanner stats, and banner-grab counters via `sweep-metrics`; JSON result chunks remain only for sweep execution/domain persistence.
  - [x] 6.6e RPerf emits throughput/loss/jitter summary metrics as canonical `MetricBatch` payloads; Go agent source tagging and gateway publishing route them to `metrics.*`.
- [ ] 6.7 Converge anomaly series identity on `(resource, metric name, point attributes, unit, kind/temporality)` instead of source-specific recipes.
