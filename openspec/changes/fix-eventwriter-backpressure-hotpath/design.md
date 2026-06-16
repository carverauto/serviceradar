## Context
The EventWriter producer is documented as a pull/back-pressure producer, but it currently creates durable push consumers with delivery subjects. NATS limits delivery by `max_ack_pending`, not by Broadway demand. When CNPG work is slow, delivered messages accumulate in the producer process and Broadway batch processors. For large metric protobuf batches, this retains substantial binary memory and can trigger redelivery if processing exceeds `ack_wait`.

The old Go `db-event-writer` is not an apples-to-apples comparison anymore. It used JetStream pull fetches and processed the older metric/log/event mix. The current pipeline changed several variables at once:
- ServiceRadar-native metrics are now canonical protobuf batches.
- The same metrics stream feeds EventWriter persistence, anomaly analysis, and capacity forecasting.
- Persistence performs device enrichment and timeseries row expansion.
- More agents and richer sysmon/SNMP payloads increase both message rate and row expansion.

This means the fix cannot be limited to "make the Elixir writer less bad." The pipeline needs an explicit throughput contract and proof that the BEAM-distributed architecture plus Rust NIF hot path can keep up with producer rate.

Live demo evidence:
- `serviceradar-event-writer-metrics` had hundreds of outstanding acks and redeliveries while its ack floor was stuck.
- The `metrics` stream held about 280 MiB in only about 1.3k messages.
- The hot BEAM process was `ServiceRadar.EventWriter.Pipeline.Broadway.BatchProcessor_metrics_0`.
- The hot core pod had OOMKilled and was climbing back toward the memory limit.
- Replaying captured demo metric protobuf payloads locally exposed a per-sample
  `series_identity_hint` mismatch debug log storm during decode and anomaly
  sample extraction. That signal must remain observable through telemetry, but
  logging one line per metric sample is itself a hot-path CPU and I/O tax.

## Goals
- Make EventWriter JetStream delivery demand-driven with pull consumers, so NATS only hands core-elx work when Broadway has capacity.
- Bound EventWriter in-process buffering so one slow stream cannot retain thousands of large payloads even if pull fetch sizing is misconfigured.
- Make per-stream JetStream consumer limits explicit and testable.
- Identify whether protobuf decode, row building, device enrichment, CNPG insert, or producer batch size is the dominant metrics hot path.
- Prove steady-state capacity: normal EventWriter processing rate must exceed observed producer rate with headroom.
- Keep high-rate metrics persistence/anomaly/capacity in the BEAM-distributed service boundary by default, with Rust/DeepCausality handling measured CPU hot paths through Rustler NIFs.
- Define an architecture path that can scale from demo-sized traffic to a 50k-agent target without depending on one core-elx Broadway pipeline.
- Preserve all telemetry flowing through NATS JetStream first.
- Provide local benchmarks so this path can be tested without using demo as the benchmark harness.

## Non-Goals
- Change database schema or move metric persistence out of EventWriter.
- Disable anomaly, capacity, or causal consumers as a way to hide the EventWriter problem.
- Guess at the slow stage without benchmark or profiling evidence.
- Claim the old Go writer's historical success proves the current protobuf/anomaly/capacity pipeline is healthy.

## Decisions
- Create EventWriter durable consumers without a `deliver_subject` and fetch from them as pull consumers.
- Couple pull fetch requests to Broadway demand and configured local in-flight capacity. The producer should not ask JetStream for messages it cannot hand to Broadway promptly.
- Keep Erlang `:queue` plus a stored length for any local pending messages. This makes the safety buffer O(1) and avoids repeated list reversal/copying in the hot path.
- Add stream-level `consumer_pull_batch_size`, `consumer_ack_wait`, and `consumer_max_ack_pending` settings to EventWriter config and the JetStream consumer helper.
- Lower the default `METRICS` EventWriter `consumer_max_ack_pending` substantially from the historical 5,000 window, and extend metric `ack_wait` enough to avoid redelivery during legitimate large inserts.
- Keep pull batch size, DB batch size, and ack window separate:
  - Pull batch size controls how many JetStream messages are requested at once.
  - DB batch size controls insert size after protobuf expansion.
  - Ack window controls how many delivered-but-unacked JetStream messages the server permits.
- Add telemetry/logging for pull requests, queue depth, in-flight messages, ack latency, processing phase timing, and overflow.
- Emit low-cardinality telemetry for producer hint drift and sample any debug
  logs, instead of logging every mismatched `series_identity_hint` on the metric
  decode/anomaly hot path.
- Treat standalone Rust or Go ingesters as benchmark controls and spike harnesses, not as the production direction for this change. The production target remains BEAM/ERTS distribution with Rustler NIFs for the measured hot loops because anomaly/capacity state needs replica-safe ownership and failover behavior. Moving the whole engine out of BEAM would require a separate proposal for distributed state ownership, partition assignment, failover, and any shared ledger or consensus mechanism.
- Optimize the current architecture before adding a second distributed system:
  - Use pull consumers and bounded local demand so each BEAM replica only accepts work it can process.
  - Keep anomaly/capacity CPU-heavy math in DeepCausality/Rust NIFs with batched APIs to amortize FFI cost.
  - Keep ERTS/OTP responsible for process supervision, replica coordination, and failure recovery.
  - Use standalone Go/Rust prototypes only to establish upper-bound throughput for decode, transform, and CNPG insert phases.
- Separate durable consumers by purpose and scale class. Persistence, anomaly, and capacity consumers should not all share one unbounded operational fate; each must have independent lag and capacity telemetry.
- Model 50k-agent scale explicitly. The design must account for per-agent sample frequency, metrics per sample, average protobuf message bytes, database row expansion, number of durable consumers, and retention window.
- For horizontal scale, prefer deterministic JetStream partition ownership over
  generic active-active consumption of the same metric stream. NATS KV can hold
  CAS/TTL partition leases, but the lease must map to a concrete pull durable or
  filtered partition subject that only the lease holder consumes. This avoids a
  custom Raft layer for the first design while keeping per-series anomaly and
  capacity state single-owned.
- Treat CNPG writes as a measured bulk-ingest boundary. The current path already
  uses chunked `Repo.insert_all`, but the 50k target requires benchmarking that
  against staged inserts and PostgreSQL COPY-style ingest before claiming the DB
  path can scale.

## Risks / Trade-offs
- Pull consumers remove prefetch pressure, but they do not make decode, enrichment, or inserts faster. If benchmarks show the persistence path cannot meet producer rate, follow-up work must optimize the measured slow phase or reduce producer batch size.
- If producer rate is permanently higher than processing rate, NATS becomes the backlog and eventually either hits retention limits or discards old metrics. That is not acceptable as a hidden steady state; the system must either scale/optimize processing, reduce/coalesce producer output, or expose a deliberate overload signal.
- Lower metric `max_ack_pending` or pull batch size may reduce peak ingest throughput when CNPG is healthy. This is intentional until benchmarks prove a higher safe value.
- Increasing metric `ack_wait` can delay redelivery after a crashed consumer. The bounded ack window limits the number of messages impacted.
- A bounded queue requires clear behavior when full. The implementation should prefer not asking NATS for more work; overflow should be exceptional and observable.

## Benchmark Plan
- Add a microbenchmark that fetches, enqueues, and drains large synthetic EventWriter events through the pull producer buffering helpers.
- Add a metrics processor benchmark using representative protobuf `MetricBatch` payloads with sysmon and SNMP rows.
- Report phase timings for protobuf decode, metric row construction, device enrichment lookup/preparation, and database insert.
- Add a producer batch-size audit for sysmon and SNMP metric publishers so the PR can say whether publishers are generating oversized protobuf messages.
- Measure live observed producer rate and compare it to benchmarked local processing rate. Record the required headroom in the PR.
- Add/identify metrics that expose EventWriter lag against stream growth so operators can tell when processing is below producer rate before retention loss occurs.
- Add a comparison benchmark or spike plan for three implementation shapes, where standalone options are controls rather than production candidates:
  1. core-elx pull EventWriter with optimized insert/enrichment;
  2. resurrected Go db-event-writer against the current protobuf payloads;
  3. standalone Rust metrics ingester/reasoner prototype against the current protobuf payloads.
- If the control benchmarks show that a non-BEAM service is required for production, create a separate OpenSpec proposal covering distributed anomaly/capacity state, partition leadership, failover semantics, replay behavior, and operational migration.
- Build the fast iteration loop outside the demo rollout path:
  - Prefer a dedicated local-dev NodePort/LoadBalancer service for stable JetStream access during long-running benchmarks.
  - Fall back to `kubectl port-forward -n demo svc/serviceradar-nats 4222:4222 8222:8222` only when direct routing is unavailable.
  - Use existing CNPG access (`cnpg-local-dev` NodePort `30455`, or `cnpg-rw-internal-lb` at `192.168.6.82:5432`) for controlled database tests.
  - Use a separate durable pull consumer name for local experiments so the live EventWriter durable is not advanced or reconfigured.
  - Use captured metric protobuf payload fixtures for repeatable decode/transform benchmarks.
  - Write DB benchmarks to disposable local CNPG, benchmark-specific tables, or a benchmark schema unless the test explicitly requires production tables.
  - Scale `serviceradar-core` to zero only for a deliberate replacement test window, and record the previous replica count for restoration.
- Document benchmark commands in `tasks.md` and keep them runnable locally under `elixir/serviceradar_core`.

## Rollback
- Revert this change to restore the previous EventWriter consumer defaults and pending-message list implementation.
- Live mitigation remains deleting/recreating the EventWriter metrics durable consumer or restarting core-elx, but that should not be the steady-state fix.
