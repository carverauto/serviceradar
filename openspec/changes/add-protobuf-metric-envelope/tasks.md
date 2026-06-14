## 1. Proto definition and codegen
- [x] 1.1 Define `proto/metric/v1/metric.proto` encoding the exact `update-anomaly-evaluation-cadence` Decision 0 field set (schema_version, resource identity, name, kind, temporality, is_monotonic, unit, points[] with value + raw_value + observed_at_unix_nano + start_time_unix_nano/reset anchor + attributes, thresholds, ingress_id, ingress_timestamp_unix_nano, ingest_identity). Reserve field numbers for additive evolution.
- [x] 1.2 Generate codecs with the repo's proto generation paths: Go (`.pb.go`), Rust (`prost`; add `rust/metric-proto` to the workspace + `causal-engine` + reuse it from `rust/addon-sdk`), Elixir (`protobuf` 0.16 typed structs). Update `BUILD.bazel`/Cargo/Mix wiring so focused codegen and tests pass.
- [x] 1.3 Add a parity test asserting the proto field set matches cadence Decision 0 (no field dropped).

## 2. Producers emit the envelope
- [x] 2.1 Go agents emit the protobuf envelope directly instead of `json.Marshal` into `StatusResponse.message`/`GatewayServiceStatus.message` for sysmon and SNMP.
- [x] 2.1f Sysmon, SNMP, and sweep regular status JSON is reduced to health/read-model summaries only; full sysmon samples, SNMP OID values, sweep aggregate counts, scanner/banner counters, and counter values are absent from status JSON and exist only in the protobuf metric envelope.
- [x] 2.1a Go agents emit ICMP check metrics as protobuf `MetricBatch` statuses (`source=icmp-metrics`) and the core JSON ICMP direct-to-CNPG path is not used for metric persistence.
- [x] 2.1b RPerf checker status emits scalar throughput/loss/jitter summaries as protobuf `MetricBatch` payloads; the Go agent tags valid rperf metric envelopes as `source=rperf-metrics`, and the gateway publishes them to `metrics.*`.
- [x] 2.1c MTR checker status emits scalar availability/hop/loss/latency/jitter summaries as protobuf `MetricBatch` payloads (`source=mtr-metrics`), and the gateway publishes those metrics to `metrics.*`; MTR trace/hop domain JSON remains only for `mtr_traces`/`mtr_hops` persistence.
- [x] 2.1d Sweep emits aggregate host counts, host/port availability, latency/loss, scanner stats, and banner-grab counters as protobuf `MetricBatch` payloads (`source=sweep-metrics`), and the gateway publishes those metrics to `metrics.*`; sweep JSON result chunks remain only for sweep execution/domain persistence.
- [x] 2.1e OTLP span-derived RED/performance samples on `otel.metrics.derived` emit `serviceradar.metric.v1.MetricBatch` protobuf payloads from both direct NATS and agent-forward backends; EventWriter decodes that protobuf into the existing `otel_metrics` row shape and rejects legacy JSON arrays.
- [x] 2.1g Agent-gateway publishes metric statuses to JetStream before any core forwarding; metric-only statuses are not forwarded to core as result payloads, and core rejects stale direct `*-metrics` status routing.
- [x] 2.1h Agent-gateway returns metric publish failures to the caller instead of acknowledging a metric payload that did not reach JetStream.
- [x] 2.2 Add protobuf metric-emit APIs to the in-repo native add-on SDKs (`go/pkg/addon/sdk`, `rust/addon-sdk`) and the Go/Rust wasm plugin SDKs (the producers the cadence change specced).
- [x] 2.2a Extend `proto/agent/addon/v1/addon.proto` (and generated Go/Rust/Elixir bindings) with a ServiceRadar metric telemetry payload kind whose `TelemetryRecord.payload` is an encoded `proto/metric/v1.MetricBatch`.
- [x] 2.2b Add SDK helpers in `go/pkg/addon/sdk` and `rust/addon-sdk` that build/stream `serviceradar.metric.v1.MetricBatch` records for native add-ons; include tests for gauge, cumulative monotonic counter, resource identity, and attributes.
- [x] 2.2b.1 Add an explicit OpenSpec delta for the in-repo native add-on SDK contract so native add-ons remain first-class protobuf metric producers.
- [x] 2.2c Update the agent/native-add-on bridge (`go/pkg/agent/addon_telemetry.go` and push-loop wrapping) and agent-gateway routing (`plugin_metrics_publisher.ex` or its replacement) so native add-on metric batch payloads are published to `metrics.*` with gateway-attested envelope identity and no JSON metrics-array conversion.
- [x] 2.2d Update the wasm plugin host bridge and Go/Rust wasm SDK helpers so plugin metrics use `TelemetryPayloadKind=SERVICERADAR_METRICS` with a base64-wrapped encoded `serviceradar.metric.v1.MetricBatch` only for the JSON wasm host ABI; the agent decodes that wrapper back to raw protobuf bytes before forwarding and rejects JSON metric objects for that payload kind.
- [x] 2.2e Document that native add-ons are first-class metric producers: SDK-authored metric records carry encoded `serviceradar.metric.v1.MetricBatch` bytes through `StreamTelemetry` and are published to JetStream `metrics.*`, not translated through JSON or plugin-result metrics.
- [x] 2.2f Reject `serviceradar.plugin_result.v1` payloads that try to include legacy `metrics[]` arrays at the Go agent boundary, and reject stale/replayed `metrics` keys in core before domain-result ingestion.
- [x] 2.2g Audit/update the standalone SDK repos (`/Users/mfreeman/src/serviceradar-sdk-go` and `/Users/mfreeman/src/serviceradar-sdk-rust`) so plugin-result metric fields/builders are removed, fixtures/examples/specs no longer promote legacy JSON metrics, and metric authors use first-class `serviceradar.metric.v1.MetricBatch` telemetry helpers with dependency-free scalar batch encoders suitable for TinyGo/wasm.
- [x] 2.2h Preserve first-party wasm plugin aggregate metrics (AXIS health, UniFi Protect counts, Proxmox inventory/resource summaries) by emitting `serviceradar.metric.v1.MetricBatch` telemetry records instead of dropping them after removing `plugin_result.metrics[]`.
- [x] 2.3 Gateway-attest `kind`/`source`/`ingest_identity` at the authenticated edge (Decision 3); a producer-supplied routing class that contradicts attestation is rejected/overridden.

## 3. Consumers decode typed fields
- [x] 3.1 Replace the JSON-first `parse_message` in EventWriter `processors/metrics.ex` with one protobuf-envelope decode that reads typed fields and stamps/reads schema_version. Keep raw OTLP on `processors/otel_metrics.ex`.
- [x] 3.2 Replace the anomaly `SampleExtractor` JSON decode + snake/camel alias probing + string-concat series identity with typed-field reads; remove the duplicate ingress-metadata decode.
- [x] 3.3 Confirm the Rust `causal-engine` does not currently consume `metrics.*`; its `serde_json::Value` subscriber is for `signals.state.>` and `signals.causal.predictions.>`. Any future metric consumer in that daemon must use the prost envelope.
- [x] 3.4 Confirm no anomaly-engine-internal shape (shards/Welford/packed NIF) appears in the producer wire format (inherited requirement, optimize anomaly-detection spec.md:62-65).

## 4. Hard cutover (no dual-accept)
- [x] 4.1 Shadow/parity gate: an offline test encodes synthetic batches both ways and asserts field-level equality (kind/temporality/monotonicity/raw_value/value/observed_at/source-identity/attributes/schema_version) + equal CNPG rows + equal anomaly sample-extraction counts.
- [x] 4.2 Single cutover commit: switch all publishers to protobuf; DELETE the JSON publishers/metric-ingest branches (sysmon/SNMP/ICMP/plugin-result, plus any add-on bridge that would translate metrics through JSON) and the JSON-first decode branches. Remove `SysmonMetricsIngestor` instead of leaving direct-to-CNPG sysmon compatibility code. Do not accept `plugin_result.metrics[]` as a compatibility path.
- [x] 4.3 Supersede `update-anomaly-evaluation-cadence`'s "version-1 flat JSON gauge remains valid" clause (coordinate with that change owner); remove the dual-accept scenario.
- [x] 4.4 Preserve JetStream-first + `Nats-Msg-Id` idempotency on the `metrics` stream + CNPG/Timescale unchanged.
- [x] 4.5 Document rollback = revert the cutover commit/tag.

## 5. Benchmark gate
- [x] 5.1 Extend `bench/anomaly_detection_scale.exs` with a decode-stage mode reusing dataset/memory/monotonic scaffolding.
- [x] 5.1a Make the JSON decode baseline build the same production-shaped row fields as the protobuf path, and record the current 50k-series decode/row-shaping comparison in `design.md`.
- [x] 5.1b Add decoded message throughput and payload MB to the benchmark output; protobuf currently wins payload bytes and summed decode/row stage work, while short BEAM wall-clock and post-GC memory deltas are recorded as noisy axes that need bottleneck notes when they do not improve.
- [x] 5.1c Add anomaly sample-extraction benchmark modes. The protobuf mode uses production `SampleExtractor.extract/1`; the legacy JSON mode is benchmark-only. Record the current extraction bottleneck and hash/identity cleanup result in `design.md`.
- [x] 5.2a Report in-memory per-source profile for canonical protobuf payloads: payload bytes, EventWriter row-build msg/s, and anomaly sample-extraction msg/s for generic, sysmon, SNMP, ICMP, MTR, sweep, rperf, wasm plugin, native add-on-shaped, and OTLP span-derived batches.
- [x] 5.2b Report environment-backed EventWriter CNPG persistence msg/s against a configured database. Use `ANOMALY_BENCH_MODE=metric_envelope_eventwriter_persist` with a unique `ANOMALY_BENCH_RUN_ID` for the CNPG insert portion.
- [x] 5.2c Report environment-backed JetStream consumer msg/s through the EventWriter Broadway producer.
- [x] 5.3 Assert the hard cutover beats the JSON baseline on payload bytes and at least one timed decode/row-shaping or anomaly sample-extraction stage-work axis. Record wall-clock/memory regressions with bottleneck notes, and record persistence/JetStream as absolute production gates because runtime JSON metric decode no longer exists there.

## 6. Observability
- [x] 6.1 Add a decode-failure counter tagged `[:reason]` from the currently-swallowed failure sites (mirror spiffe.verification.failure / otlp_relay.record_rejected).
- [x] 6.2 Add a schema_version distribution signal.
- [x] 6.3 Reuse `SignalTelemetry` received/written/rejected for envelope batch throughput + drops; add an envelope decode/extract latency distribution.
- [x] 6.4 Register the anomaly Pipeline `[:serviceradar, :anomaly_detection, :consumer, *]` events in `*_metrics/0` (close the existing gap); ensure all new metrics reach `Telemetry.metrics/0`.

## 7. Validation
- [x] 7.1 `openspec validate add-protobuf-metric-envelope --strict`.
- [x] 7.2 Coordinate dependencies: `add-monotonic-counter-metric-semantics` (counter raw_value + reset anchors in the proto), `add-cgroup-v2-tenant-metrics`.
