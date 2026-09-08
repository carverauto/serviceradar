# Change: Fix metrics ingestion backpressure hot path

## Why
Demo shows sustained CPU growth and core-elx memory growth when the EventWriter metrics consumer receives large JetStream metric batches faster than it can decode, enrich, insert, and ack them. The current EventWriter producer is still push-delivered by JetStream, so NATS can deliver payloads ahead of Broadway demand and force core-elx to retain large protobuf binaries while database/enrichment work catches up.

The real question is whether the new protobuf metrics pipeline can process producer rate after adding anomaly detection, capacity planning, device enrichment, and durable fanout. This change must measure that path directly and make JetStream delivery demand-driven so slow processing remains bounded instead of becoming a BEAM mailbox/binary-memory problem.

## What Changes
- Replace EventWriter push consumers with pull consumers that request work only when Broadway has demand and local in-flight capacity.
- Keep bounded in-process buffering as a safety guard, not as the primary backpressure mechanism.
- Add per-stream EventWriter consumer controls for pull batch size, `ack_wait`, and `max_ack_pending`, with conservative defaults for high-payload metric streams.
- Ensure the metrics stream cannot deliver thousands of large unacked protobuf batches into one BEAM process.
- For the scope of this change, keep the production architecture distributed through BEAM/ERTS, with Rust/DeepCausality used for NIF-backed hot-path computation. The longer-term execution location of anomaly/capacity (edge vs central) is decided by the `move-anomaly-detection-to-edge` and `add-delta-metrics-lakehouse` changes and is intentionally not foreclosed here.
- Add focused tests for producer buffering, consumer config payloads, and runtime stream settings.
- Add reproducible local benchmarks that break down metric protobuf processing into decode, row construction, device enrichment, and insert phases.
- Investigate producer-side metric batch sizes so oversized protobuf batches can be fixed at the source if persistence benchmarks show message size is the bottleneck.
- Bound sysmon process telemetry defaults so a catch-all profile cannot accidentally publish every process on every host into the raw metrics stream.
- Add JetStream durable-consumer lag telemetry for EventWriter pending, ack-pending, redelivery, and retention-risk state.
- Define and test a steady-state throughput target: EventWriter processing rate must exceed observed producer rate with headroom, or the system must apply an explicit overload policy instead of silently accumulating backlog.
- Size the 50k-agent target and record the corrected projection (the original projection scaled a payload that was ~94% per-process rows; with the process cap that target drops by ~10x). The full ingestion architecture — sharding, edge aggregation/coalescing, durable consumer fanout limits, and the raw-storage tier — is carried by the `move-anomaly-detection-to-edge` and `add-delta-metrics-lakehouse` changes, not this one.
- Add a local development and benchmark loop that connects to demo NATS/CNPG without rolling the demo namespace for every iteration.

## Impact
- Affected specs: observability-signals
- Affected code: `elixir/serviceradar_core/lib/serviceradar/event_writer/*`, `elixir/serviceradar_core/lib/serviceradar/nats/jetstream_consumer.ex`, `elixir/serviceradar_core*/config/runtime.exs`, metric publisher and anomaly/capacity consumer boundaries
- Affected runtime: core-elx EventWriter JetStream consumers for `metrics.>`, anomaly/capacity consumers, and local benchmark/spike ingesters that must not advance live durables
