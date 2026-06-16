## 1. Proposal
- [x] 1.1 Validate the OpenSpec change with `openspec validate fix-eventwriter-backpressure-hotpath --strict`.

## 2. Implementation
- [x] 2.1 Add fixture replay support to the local anomaly/metric benchmark so captured demo protobuf payloads can be decoded, row-built, and sample-extracted without rolling Kubernetes workloads.
- [x] 2.2 Capture representative metric protobuf payload fixtures from demo NATS into ignored local files for repeatable local benchmarks.
- [x] 2.3 Replace EventWriter push durable consumers with pull durable consumers that do not set `deliver_subject`.
- [x] 2.4 Couple pull fetch requests to Broadway demand, configured pull batch size, and local in-flight capacity.
- [x] 2.5 Keep a bounded FIFO queue with queue length accounting as a safety buffer for messages already fetched.
- [x] 2.6 Add per-stream `consumer_pull_batch_size`, `consumer_ack_wait`, and `consumer_max_ack_pending` config plumbing through EventWriter config, runtime config, and `JetstreamConsumer.ensure_durable/2`.
- [x] 2.7 Set conservative EventWriter defaults for the `METRICS` stream so large protobuf batches cannot accumulate thousands of unacked messages.
- [x] 2.8 Add telemetry/logging for EventWriter pull requests, queue depth, in-flight messages, ack latency, processing phase timing, and overflow behavior.
- [x] 2.9 Replace per-sample `series_identity_hint` mismatch debug logs with low-cardinality telemetry and sampled debug logging.

## 3. Tests And Benchmarks
- [x] 3.1 Add unit tests for pull fetch sizing, demand coupling, queue enqueue/dequeue behavior, bounded overflow, and drain ordering.
- [x] 3.2 Add tests proving JetStream consumer payloads honor pull mode, per-stream ack wait, and max ack pending values.
- [x] 3.3 Add runtime config tests for default `METRICS` stream pull and ack limits.
- [x] 3.4 Add local benchmarks for EventWriter pull/buffering and metric protobuf batch processing.
- [x] 3.5 Add benchmark/profiling output that separates protobuf decode, row construction, and anomaly sample extraction phases for captured protobuf payloads.
- [x] 3.6 Measure live producer rate and compare it to benchmarked EventWriter processing rate with documented headroom.
- [x] 3.7 Audit sysmon and SNMP metric publisher batch sizes and document whether producer-side batching needs follow-up changes.
- [x] 3.8 Add or identify telemetry for EventWriter stream lag, in-flight messages, and retention-risk conditions.
- [ ] 3.9 Compare implementation controls for the current protobuf pipeline: optimized BEAM/ERTS core-elx, resurrected Go db-event-writer benchmark harness, and standalone Rust benchmark harness.
- [x] 3.10 Document a 50k-agent sizing model covering message rate, row expansion, durable consumer fanout, NATS retention, DB write throughput, and anomaly/capacity compute.
- [ ] 3.11 Add a Rust benchmark spike for protobuf decode, transform, anomaly/capacity hook points, and batched CNPG writes as an upper-bound control, not a production replacement.
- [x] 3.12 Run targeted Elixir tests for EventWriter/NATS config.
- [x] 3.13 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core_elx`.
- [x] 3.14 Benchmark CNPG bulk ingest with captured metric rows, comparing current `Repo.insert_all` against a staged/COPY-style path.
- [x] 3.15 Benchmark first-pass parallel CNPG COPY with captured metric rows to test whether more client writers scale the current hypertable path.
- [x] 3.16 Benchmark staged/minimally indexed CNPG COPY plus final-table insert with captured metric rows.
- [ ] 3.17 Benchmark production-like CNPG partition/index settings before deciding whether a different metrics store is required.
- [x] 3.18 Follow-up proposal: add a process telemetry rollup/detail mode so large fleets persist process counts/top-N summaries by default and reserve per-process raw rows for explicit troubleshooting windows.

## 4. Delivery
- [ ] 4.1 Summarize benchmark results and expected demo impact in the PR.
- [ ] 4.2 Open a Forgejo PR against `staging` from `fix/eventwriter-backpressure-hotpath`.
