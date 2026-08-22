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

**Part 2 — NOT IN THIS CHANGE. It belongs to the vertical slice.**

A throughput benchmark must exercise the SAME production entrypoint the vertical slice uses. If
it is built here it will grow benchmark-only glue — a private approximation of ingress — and the
project then has two models of the same path, one of which nothing in production calls. That is
the failure this change exists to complain about, reproduced one layer up.

So the throughput work moves INTO `unify-sweep-results-proto`'s vertical-slice implementation
rather than preceding it as a detour. Two of its stages are also still being defined:
`freeze-edge-record-v1-abi` 1.5-k owns projected-cost ENUMERATION and 1.5-n owns the Elixir
structural record boundary, and a benchmark that measured those before they are settled would
pin a shape that is still moving.

NAMING IS PART OF THE BOUNDARY. Until gRPC, JetStream, EventWriter and CNPG are in the
measurement it is a **composed ingress CPU benchmark** — not end-to-end, and not deployment
throughput. It may report records/sec, hosts/sec, bytes/sec and allocations over: raw extraction
and size bounds, frame/record decode and validation, real signature verification against a warm
in-memory trust resolver, decompression, body validation, correlation, and projected-cost
enumeration. A number covering that much is genuinely useful and still is not capacity.

The real pipeline benchmark comes immediately after the slice is green, and only then may the
words end-to-end or throughput attach to it.

## Impact

- **Affected specs:** `edge-pipeline-benchmarks` (new capability)
- **Affected code:**
  - `go/pkg/edge/edgerecord/BUILD.bazel` and the other Go packages carrying `Benchmark*` functions
  - `elixir/serviceradar_core/BUILD.bazel`, `elixir/serviceradar_core/bench/**`
  - `rust/netprobe/BUILD.bazel`, `rust/netprobe/benches/**`
  - `//buildbuddy.yaml` — one added step
- **Not in scope:** any performance THRESHOLD, any optimisation work, and any change to what the
  benchmarks measure. Part 1 changes only whether they run.
- **Moved, not deferred:** the throughput benchmark belongs to `unify-sweep-results-proto`'s
  vertical-slice implementation, so it exercises production composition rather than becoming a
  second independently proven model of ingress. It additionally depends on
  `freeze-edge-record-v1-abi` 1.5-k and 1.5-n, which define two of the stages it would measure.
- **Available dependency:** a real NATS JetStream instance exists in `sr-testing`, so neither the
  vertical slice nor the throughput benchmark needs to mock the PubAck hop. A measurement taken
  against a real broker describes the system; one taken against a mock describes the harness.

## Risk

The honest risk is that this change is itself a horizontal proof surface. What remains here is
small: it makes existing benchmarks run and keeps their "not production ingress" disclaimers
intact. The expensive half is not deferred but REASSIGNED, to the slice that will own the
production entrypoint it must measure.
