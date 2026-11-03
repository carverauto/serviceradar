## 1. Proposal

- [x] 1.1 Establish what exists and what runs it: benchmarks in Go, Elixir and Rust; no `-bench`,
      `benchmem`, `mix bench` or `criterion` invocation in `.github/workflows/`, `//buildbuddy.yaml`
      or the `Makefile`; no Bazel target that runs one; zero `acceptance`-tagged targets.
- [x] 1.2 Record that the one edge benchmark disclaims being a capacity figure in its own header,
      so "add a throughput number" is new work rather than wiring up an existing one.
- [x] 1.3 Draft this proposal and the `edge-pipeline-benchmarks` spec delta.
- [x] 1.4 Validate with `openspec validate add-edge-pipeline-benchmarks --strict`.
- [ ] 1.5 Approval before implementation.

## 2. Execute the Go benchmarks

- [ ] 2.1 Add a Bazel target per Go package carrying `Benchmark*` that RUNS the benchmarks
      (`-test.bench`, `-test.benchtime` bounded so a CI run is time-boxed), separate from the
      correctness `go_test` so a slow benchmark never delays the unit sweep.
- [ ] 2.2 Give each target a bounded `benchtime` and assert the target FAILS if it matched no
      benchmark. A benchmark runner that silently matches nothing reports success, which is the
      same failure mode as not running it at all.
- [ ] 2.3 Emit the results as a declared build artifact rather than only to the log.

## 3. Execute the Elixir benchmarks

- [ ] 3.1 Add a Bazel target that runs each script under `elixir/serviceradar_core/bench/`.
- [ ] 3.2 Keep `bench/sweep_ingress_fixtures.exs` a FIXTURE GENERATOR, not a benchmark target: it
      is required at module level by `sweep_bench_fixture_test.exs` and is already a declared
      input of the test tiers. Running it as a benchmark would make one file two things.
- [ ] 3.3 Separate the benchmarks that need a database (`metric_fixture_cnpg_insert`) from those
      that do not, so the database-free ones can run without the fixture lifecycle.

## 4. Execute the Rust benchmarks

- [ ] 4.1 Add a Bazel target that runs `rust/netprobe/benches`.
- [ ] 4.2 Confirm the vendored `third_party/netprobe_ebpf_vendor/**/benches` are NOT swept in:
      those are dependencies' own benchmarks and are not this project's to run.

## 5. Run them in CI, without gating

- [ ] 5.1 Add ONE `//buildbuddy.yaml` step that runs the benchmark targets after the test steps.
- [ ] 5.2 Record the numbers as artifacts. NO THRESHOLD: a benchmark on a shared runner is noisy,
      and a threshold set before its variance is known produces false failures and then gets
      muted, which is worse than no gate at all.
- [ ] 5.3 Collect enough runs to state each benchmark's observed variance, so a later proposal to
      gate can be argued from data rather than from a round number.

## 6. Pipeline throughput -- tracked in section 7

Items 6.1-6.3 record the original assignment. Section 7 holds the throughput
and capacity tasks.

- [x] 6.1 Record that the throughput benchmark is NOT part of this change. It must exercise the
      same production entrypoint the vertical slice uses; built here it would grow
      benchmark-only glue and become a second model of ingress that nothing in production calls.
- [x] 6.2 Record its two additional dependencies: `freeze-edge-record-v1-abi` 1.5-k
      (projected-cost enumeration) and 1.5-n (the Elixir structural record boundary) define
      stages it would measure, and both are still open.
- [x] 6.3 Record the naming boundary: until gRPC, JetStream, EventWriter and CNPG are in the
      measurement it is a COMPOSED INGRESS CPU BENCHMARK -- never "end-to-end", never
      "deployment throughput".

## 7. Capacity baselines and scale benchmarks (moved from `unify-sweep-results-proto`)

These moved here on 2026-11-02 when `unify-sweep-results-proto` was reconciled against `staging`; they keep their
original text and number. They are measurements, so the no-threshold rule of section 5 applies
until a baseline and its variance exist.

- [ ] 7.1 (was `unify-sweep-results-proto` 0.1) Capture 1k, 10k, 100k, and 1M target fixtures for ICMP plus zero,
  five, ten, and fifty TCP ports, including realistic sparse open ports and
  failures.
  Remaining as of the move (2026-11-02): follow-up change (`add-edge-pipeline-benchmarks`
  owns fixture-driven throughput).
- [ ] 7.2 (was `unify-sweep-results-proto` 0.2) Capture scheduled, sweep-profile, ad-hoc, and on-demand MTR fixtures
  with ECMP, MPLS, ASN, DNS, unreachable targets, partial hops, and maximum
  configured bounds.
  Remaining as of the move (2026-11-02): follow-up; MTR fixtures now serve
  `move-agent-telemetry-to-edge-records` task 3.1.
- [ ] 7.3 (was `unify-sweep-results-proto` 0.3) Measure current end-to-end JSON and duplicate `MetricBatch` bytes,
  CPU, allocations, peak RSS, BEAM mailbox/queue bytes, gateway loss behavior,
  NATS traffic, database rows, index/WAL bytes, and query latency.
  Remaining as of the move (2026-11-02): follow-up (`add-edge-pipeline-benchmarks`).
- [ ] 7.4 (was `unify-sweep-results-proto` 0.4) Produce and approve a capacity plan for burst rate, supported outage,
  agent spool bytes, JetStream logical and replica bytes per physical stream
  shard, stream/consumer RAFT and connection cardinality, consumer drain rate,
  shared CNPG transaction credits/ingest rate, raw retention, and MTR probe
  budget. Include correctness-metadata retirement bucket width, live partition
  count, row/index-byte ceiling, partition-retirement throughput, exceptional
  hold capacity, and accepted domain-replay horizon.
  Remaining as of the move (2026-11-02): follow-up capacity plan; no approved figures
  exist.
- [ ] 7.5 (was `unify-sweep-results-proto` 0.7) Capture representative Wasm metric/event/inventory output, native
  add-on telemetry and OTLP relay, and embedded Armis discovery fixtures.
  Measure producer-to-agent copies, JSON/base64 amplification, queue-loss
  windows, peak memory, records/bytes per run, and downstream row/write cost.
  Remaining as of the move (2026-11-02): follow-up; the plugin, OTLP and flow contracts
  (#6245, #6262, #6264) carry synthetic fixtures only.
- [ ] 7.6 (was `unify-sweep-results-proto` 8.4) Benchmark the full matrix through 1M hosts and a 72-hour soak; require
  at least 10,000 host observations/second aggregate on a fully documented
  reference topology, a 1M-host ten-port drain within 6 minutes, bounded result
  RSS below 256 MiB independent of scan size, measured domain-row/WAL rates, no
  hot reconcile tuple/index page, AGE edge drain above live-plus-catch-up with
  bounded lag/lock/WAL cost, and an approved MTR throughput/storage budget. Add
  an accelerated long-horizon churn/capacity test for delivery/ingest/batch/
  terminal/sweep/MTR identity, outbox, work, recovery, DLQ catalog, stream-map,
  plan/fence/key metadata, and watermark GC. Include worst-case timer-fragmented
  frames from 1,000 low-rate agents and record messages/second, transactions/
  second, rows/transaction, commit fsyncs, and WAL per observation for adaptive
  grouping versus one-message transactions; fail if fragmentation breaks the
  ingest or interactive-latency gate. Prove correctness rows/index bytes converge
  to a bounded sawtooth/plateau under partition retirement plus configured holds;
  linear steady-state growth or bulk row-delete/vacuum cleanup fails the gate.
  Remaining as of the move (2026-11-02): follow-up (`add-edge-pipeline-benchmarks`).
