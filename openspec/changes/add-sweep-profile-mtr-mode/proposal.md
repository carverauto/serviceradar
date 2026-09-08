# Change: MTR as a first-class scheduled sweep mode

## Why

`add-adhoc-network-scan` made MTR a first-class `SweepMode` (`ModeMTR`) and ran
it inside the ad-hoc scan handler. Scheduled sweeps still can't run MTR — a
sweep profile only offers `icmp` and `tcp`. Operators want a scheduled profile
to reach a target set with ICMP, TCP ports, **and** MTR in one place, and the
long-term direction is to route all MTR through the sweep engine (folding in
the standalone MTR checker; see #4669).

Today the sweep engine (`NetworkSweeper` -> `sweepBatchRunner`) batches targets
into ICMP/TCP scanners and aggregates per-host results into
`models.HostResult` (which already unifies `ICMPStatus` + `PortResults` per
host). MTR is absent from that pipeline, and MTR's per-hop trace does not fit
the host/port model. This change makes MTR a first-class mode **inside** the
sweep engine and extends the per-host aggregate to carry MTR too, so one result
shape covers all three modes.

## What Changes

### Unified per-host result shape (all modes)
- **EXTEND** `models.HostResult` with an `MTRStatus *MTRStatus` field
  (`Reached bool`, `RoundTrip time.Duration`, `PacketLoss float64`,
  `TotalHops int`, plus a reference/handle to the full trace). `HostResult`
  becomes the single per-host aggregate across `icmp` (ICMPStatus), `tcp`
  (PortResults), and `mtr` (MTRStatus) — no parallel result type.
- The full per-hop MTR trace is not embedded in every sweep summary (it is
  large); the reachability summary lives on `HostResult.MTRStatus`, and the
  trace is emitted separately to the MTR results path (below).

### MTR batch path in the sweep engine (Go)
- **ADD** a `ModeMTR` case to `sweepBatchRunner.addTarget` and a bounded MTR
  worker path (reusing `mtr.Tracer`, like the ad-hoc handler) so MTR targets
  run in the same sweep pass as ICMP/TCP without blocking them.
- **ADD** MTR handling to the sweep aggregation/metadata paths that currently
  switch on `ModeICMP`/`ModeTCP`/`ModeTCPConnect`
  (`base_processor.go`, `memory_store.go`, `sweeper_metadata_builders.go`,
  `sweeper_target_generation.go`): MTR contributes to host availability
  (`Available = TargetReached`) and populates `HostResult.MTRStatus`.
- **ADD** MTR to target generation so a sweep config with `mtr` in
  `SweepModes` generates MTR-mode targets for the CIDR/host set.

### Results: reachability in the sweep + full trace to mtr_traces
- **Reachability**: MTR-mode host results flow through the existing sweep
  results pipeline (into `ocsf_network_activity` / `sweep_host_results`) via
  `HostResult.MTRStatus`, so MTR targets appear in the sweep's up/down view.
- **Full trace**: the sweep engine emits each MTR trace onto the MTR results
  path so it lands in `mtr_traces`/`mtr_hops` (reusing the existing
  `mtr-metrics` envelope + ingestion — the same dual-store pattern the ad-hoc
  scan uses). Honors metrics-through-JetStream.

### Sweep profile schema + config compiler (Elixir)
- **ALLOW** `mtr` in `ServiceRadar.SweepJobs.SweepProfile` `sweep_modes`
  (currently `icmp`/`tcp`), plus optional MTR options on the profile
  (`mtr_protocol`, `mtr_max_hops`).
- **EMIT** `mtr` (and its options) into the compiled agent sweep config so a
  scheduled profile with MTR enabled runs MTR on its interval through the
  sweep engine.

### Settings UI
- **ADD** an MTR option to the Settings sweep-profile editor alongside ICMP/TCP
  (and MTR protocol / max-hops inputs), gated by the existing sweep-profile
  permissions.

## Impact

- **Affected specs**: `network-discovery` (MODIFIED — sweep modes now include
  MTR).
- **Affected code**:
  - Go: `go/pkg/models/sweep.go` (`MTRStatus`, `HostResult`),
    `go/pkg/sweeper/sweeper_batch_runner.go`, `base_processor.go`,
    `memory_store.go`, `sweeper_metadata_builders.go`,
    `sweeper_target_generation.go`, and the sweep result emission path;
    reuse `go/pkg/mtr`.
  - Elixir: `sweep_jobs/sweep_profile.ex` (+ migration if new columns),
    the sweep-config compiler/distribution, Settings sweep-profile LiveView.
- **Compatibility**: additive. Profiles without `mtr` behave exactly as
  before; `HostResult.MTRStatus` is `omitempty`. The standalone MTR checker is
  unchanged by this change (its retirement — routing all MTR through the sweep
  engine — is the #4669 follow-on).
- **Depends on**: `ModeMTR` and `mtr.Tracer` (already in staging via
  `add-adhoc-network-scan`).
