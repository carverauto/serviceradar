# Change: Run the benchmarks that already exist, then measure pipeline throughput

## Why

ServiceRadar has benchmarks in all three runtimes and **nothing executes any of them**.

| runtime | benchmarks | what runs them |
|---|---|---|
| Go | ~10 files, incl. `go/pkg/edge/edgerecord/sweep_ingress_benchmark_test.go` | nothing |
| Elixir | `elixir/serviceradar_core/bench/` — `sweep_ingress`, `event_writer_pull_buffering`, `metric_fixture_cnpg_insert`, `metric_fixture_profile` | nothing |
| Rust | `rust/netprobe/benches` | nothing |

There is no `-bench`, `benchmem`, `mix bench`, or `criterion` invocation in `.github/workflows/`,
`//buildbuddy.yaml`, or the `Makefile`, and no Bazel target that runs one. Go benchmarks are
COMPILED by `bazel test` but never EXECUTED — `go test` skips them without `-bench` — so today
they prove only that they still build. The Elixir `bench/*.exs` are plain scripts nobody invokes.

That is a slow leak rather than an outage: a benchmark nobody runs still passes review, still
looks like coverage on a file listing, and rots until the day someone needs a number and finds it
does not run. One of them is already load-bearing for something else — `bench/sweep_ingress_fixtures.exs`
is the shared fixture matrix `sweep_bench_fixture_test.exs` requires at module level, and a
missing Bazel input for it aborted an entire integration shard.

**Separately, no benchmark measures throughput.** The one edge benchmark says so itself:

> THIS IS NOT PRODUCTION INGRESS, and its numbers are not a capacity figure. Stage 1 is
> `proto.Unmarshal` alone; stage 4 is unmarshal + body validation + the private join. There is NO
> extraction, NO `ValidateSweepRecord`, NO trust resolution, NO signature verification and NO
> decompression. What it supports is the SHAPE of the cost — decode dominates, the work is linear
> — not hosts/sec for a deployment.

So there is no answer to "how many records per second does this deployment ingest", and no
baseline to notice a regression against.

## What Changes

**Part 1 — execute what exists. Buildable now, no dependencies.**

- Add Bazel targets that RUN each benchmark rather than only compiling it, in all three runtimes.
- Run them in CI and RECORD the numbers. **No threshold gate.** A benchmark on a shared CI
  runner is noisy, and a threshold set before its variance is measured produces false failures
  and then gets muted, which is worse than no gate.
- Publish each run's numbers as a build artifact so a baseline and its variance can be
  established from real data before anyone proposes gating on it.

**Part 2 — measure throughput on the composed path. BLOCKED, deliberately.**

Throughput of the ingest pipeline can only be measured once the pipeline runs end to end:
`record -> agent spool -> mTLS gRPC -> gateway -> JetStream PubAck -> EventWriter -> idempotent
CNPG transaction -> query`. That is precisely the FIRST GREEN VERTICAL SLICE milestone in
`unify-sweep-results-proto`, which states that the composed runtime result must not be displaced
by further horizontal proof surfaces.

A pipeline throughput benchmark built before that slice exists would have to stub most of the
path, and would therefore measure a fiction — the same defect the existing edge benchmark
already documents about itself. **So Part 2 does not start until the vertical slice is green,**
and this proposal records that dependency rather than competing with it.

## Impact

- **Affected specs:** `edge-pipeline-benchmarks` (new capability)
- **Affected code:**
  - `go/pkg/edge/edgerecord/BUILD.bazel` and the other Go packages carrying `Benchmark*` functions
  - `elixir/serviceradar_core/BUILD.bazel`, `elixir/serviceradar_core/bench/**`
  - `rust/netprobe/BUILD.bazel`, `rust/netprobe/benches/**`
  - `//buildbuddy.yaml` — one added step
- **Not in scope:** any performance THRESHOLD, any optimisation work, and any change to what the
  benchmarks measure. Part 1 changes only whether they run.
- **Explicitly deferred:** Part 2 until the `unify-sweep-results-proto` vertical slice is green.
- **Available dependency:** a real NATS JetStream instance exists in `sr-testing`, so neither the
  vertical slice nor the throughput benchmark needs to mock the PubAck hop. A measurement taken
  against a real broker describes the system; one taken against a mock describes the harness.

## Risk

The honest risk is that this change is itself a horizontal proof surface. Part 1 is small and
prevents rot in work already paid for; Part 2 is the part with real cost, and it is gated behind
the composed result rather than allowed to precede it.
