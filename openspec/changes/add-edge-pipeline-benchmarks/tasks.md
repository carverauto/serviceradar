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

## 6. Pipeline throughput -- MOVED to the vertical slice, not tracked here

- [x] 6.1 Record that the throughput benchmark is NOT part of this change. It must exercise the
      same production entrypoint the vertical slice uses; built here it would grow
      benchmark-only glue and become a second model of ingress that nothing in production calls.
- [x] 6.2 Record its two additional dependencies: `freeze-edge-record-v1-abi` 1.5-k
      (projected-cost enumeration) and 1.5-n (the Elixir structural record boundary) define
      stages it would measure, and both are still open.
- [x] 6.3 Record the naming boundary: until gRPC, JetStream, EventWriter and CNPG are in the
      measurement it is a COMPOSED INGRESS CPU BENCHMARK -- never "end-to-end", never
      "deployment throughput".
