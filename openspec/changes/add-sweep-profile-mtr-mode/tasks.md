# Tasks: MTR as a first-class scheduled sweep mode

## 1. Unified result shape (Go models)
- [ ] 1.1 Add `models.MTRStatus` (`Reached`, `RoundTrip`, `PacketLoss`,
  `TotalHops`) and `HostResult.MTRStatus *MTRStatus` (`omitempty`) in
  `go/pkg/models/sweep.go`.
- [ ] 1.2 Update `DeepCopyHostResult` (and any HostResult copiers) to copy
  `MTRStatus`.

## 2. MTR batch path in the sweep engine (Go)
- [ ] 2.1 `sweeper_batch_runner.go`: add `case models.ModeMTR` in `addTarget`;
  add a bounded MTR worker pool (reuse `mtr.Tracer`, mirror the ad-hoc
  handler's concurrency) that runs traces without blocking ICMP/TCP; flush on
  batch/finalize.
- [ ] 2.2 `sweeper_target_generation.go`: include `mtr` in
  `effectiveSweepModesForCIDR` and generate `ModeMTR` targets.
- [ ] 2.3 `base_processor.go`, `memory_store.go`,
  `sweeper_metadata_builders.go`: add `ModeMTR` arms so MTR sets host
  availability + populates `HostResult.MTRStatus`.
- [ ] 2.4 Emit the full `mtr.TraceResult` per MTR target onto the MTR results
  path (`mtr-metrics` MetricBatch) so traces land in `mtr_traces`/`mtr_hops`
  via JetStream + event-writer (no direct DB write).
- [ ] 2.5 Go tests: mixed `[icmp,tcp,mtr]` sweep yields all three in
  `HostResult`; MTR-only sweep sets availability + MTRStatus; trace emitted.
  `gofmt` + BUILD.bazel updates; `bazel build //go/pkg/sweeper/...
  //go/pkg/agent/... //go/pkg/models/...`.

## 3. Sweep profile schema + compiler (Elixir)
- [ ] 3.1 `sweep_jobs/sweep_profile.ex`: allow `"mtr"` in `sweep_modes`; add
  `mtr_protocol` / `mtr_max_hops` attributes (+ migration if columns are new).
- [ ] 3.2 Sweep-config compiler/distribution: emit `mtr` (+ options) into the
  compiled agent sweep config.
- [ ] 3.3 ExUnit: profile with `mtr` compiles to a config carrying the mode +
  options (integration where DB-backed).

## 4. Settings UI (web-ng)
- [ ] 4.1 Sweep-profile editor LiveView: MTR mode toggle beside ICMP/TCP +
  MTR protocol / max-hops inputs, gated by existing sweep-profile permissions.
- [ ] 4.2 LiveView test: MTR toggle renders + persists into the profile.

## 5. Verification
- [ ] 5.1 `go test ./go/pkg/sweeper/... ./go/pkg/models/...` +
  `bazel build` the affected targets.
- [ ] 5.2 `mix compile --warnings-as-errors` (core + web-ng);
  focused ExUnit against srql-fixtures.
- [ ] 5.3 `openspec validate add-sweep-profile-mtr-mode --strict`.
- [ ] 5.4 Manual/e2e note: a scheduled profile with `[icmp,tcp,mtr]` produces
  reachability in the sweep view and traces in `mtr_traces`.
