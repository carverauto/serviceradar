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
- [x] 3.9 DONE — `sizing.md` now compares the three implementation controls. Production remains optimized BEAM/ERTS core-elx for this change (pull JetStream consumers, bounded producer buffering, low-cardinality telemetry, EventWriter decode/row benchmarks, live CNPG `insert_all`/COPY/staged-COPY results). The standalone Rust `metrics-protobuf-bench` is an upper-bound protobuf decode/transform/anomaly-hook/capacity-hook/temp-table-write harness over the same payloads. The historical Go db-event-writer is explicitly not a valid direct comparison until rebuilt for the current `MetricBatch` shape, row expansion, hook points, and CNPG schema; treating it as future benchmark work avoids using stale evidence to justify a rewrite.
- [x] 3.10 Document a 50k-agent sizing model covering message rate, row expansion, durable consumer fanout, NATS retention, DB write throughput, and anomaly/capacity compute.
- [x] 3.11 Add a Rust benchmark spike for protobuf decode, transform, anomaly/capacity hook points, and batched CNPG writes as an upper-bound control, not a production replacement.
- [x] 3.12 Run targeted Elixir tests for EventWriter/NATS config.
- [x] 3.13 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core_elx`.
- [x] 3.14 Benchmark CNPG bulk ingest with captured metric rows, comparing current `Repo.insert_all` against a staged/COPY-style path.
- [x] 3.15 Benchmark first-pass parallel CNPG COPY with captured metric rows to test whether more client writers scale the current hypertable path.
- [x] 3.16 Benchmark staged/minimally indexed CNPG COPY plus final-table insert with captured metric rows.
- [x] 3.17 DONE — live demo CNPG benchmarks exercised the real `platform.timeseries_metrics` Timescale hypertable/index path, not a synthetic target: TimescaleDB 2.24.0, 7-day `timestamp` chunks, 2 active chunks during the check, compression disabled, and six write-path indexes (`timeseries_metrics_pkey`, device, device/if/metric/time, metric name, and two timestamp indexes). Results documented in `sizing.md`: `insert_all` ~6.3k rows/sec, direct COPY ~19.7k rows/sec, four-worker parallel COPY ~15.8k rows/sec for 45.3k rows, staged-COPY/final-insert ~9.6-13.2k rows/sec. Conclusion: the current single-hypertable/index path is not a 50k-agent raw-row design; this does not by itself prove CNPG/Timescale must be replaced before testing partitioned/reduced-index/hardware-isolated paths and raw-row reduction.
- [x] 3.18 Follow-up proposal: add a process telemetry rollup/detail mode so large fleets persist process counts/top-N summaries by default and reserve per-process raw rows for explicit troubleshooting windows.

## 4. Delivery
- [x] 4.1 Summarize benchmark results and expected demo impact in the PR.
- [x] 4.2 Open a Forgejo PR against `staging` from `fix/eventwriter-backpressure-hotpath`.
