# Design: MTR as a first-class scheduled sweep mode

## Context

The sweep engine batches targets by mode: `sweepBatchRunner.addTarget`
switches on `models.SweepMode` and feeds ICMP/TCP scanners, and per-host
results aggregate into `models.HostResult` (already carrying `ICMPStatus` +
`PortResults` + `SweepModes`). MTR is a first-class `SweepMode` (`ModeMTR`,
added by `add-adhoc-network-scan`) but the scheduled sweep pipeline has no MTR
path. MTR's per-hop trace is structurally unlike host/port results, so the
design question is how MTR fits the pipeline. The chosen answer (per approval):
run MTR **inside** `NetworkSweeper`, contribute reachability to the sweep, and
emit the full trace to `mtr_traces`.

## Decisions

### D1: Extend `HostResult` — one shape for all modes
`HostResult` already unifies ICMP + TCP per host. Add `MTRStatus *MTRStatus`:

```go
type MTRStatus struct {
    Reached    bool
    RoundTrip  time.Duration // end-to-end RTT (final hop avg)
    PacketLoss float64
    TotalHops  int
}

type HostResult struct {
    // ...existing fields...
    ICMPStatus *ICMPStatus  `json:"icmp_status,omitempty"`
    MTRStatus  *MTRStatus   `json:"mtr_status,omitempty"` // NEW
}
```

`HostResult` is the single per-host aggregate across `icmp`/`tcp`/`mtr`. This
avoids a parallel result type and flows through every existing consumer
unchanged (the field is `omitempty`). The full trace is **not** on
`HostResult` (too large for a sweep summary); only the reachability summary is.

### D2: Bounded MTR batch path in `sweepBatchRunner`
Add `case models.ModeMTR` to `addTarget`. MTR is heavy, so unlike the
fire-and-batch ICMP/TCP scanners it runs via a bounded worker pool over
`mtr.Tracer` (mirroring the ad-hoc handler's `runAdhocMTR`), so a large MTR
target set never blocks the ICMP/TCP phases. Each completed trace produces:
- an internal `Result`/`HostResult` update setting `Available = TargetReached`
  and `MTRStatus`, and
- the full `mtr.TraceResult` handed to the trace-emission path (D3).

The switch statements in `base_processor.go`, `memory_store.go`,
`sweeper_metadata_builders.go`, and `sweeper_target_generation.go` gain
`ModeMTR` arms consistent with how they treat ICMP (a reachability-style mode).

### D3: Two emissions, both rule-compliant
- **Reachability** rides the existing sweep-results/sweep-metrics pipeline
  (`push_loop_sweep_results.go` -> JetStream -> event-writer ->
  `ocsf_network_activity`/`sweep_host_results`). `MTRStatus` maps into the
  host result the same way `ICMPStatus` does.
- **Full trace** is emitted on the existing MTR results path: the sweep engine
  builds the `mtr-metrics` MetricBatch (the scheduled MTR checker's envelope)
  per trace, so traces land in `mtr_traces`/`mtr_hops` via the normal
  JetStream + event-writer route. No direct DB write; no new stream.

### D4: Profile -> compiler -> agent config
`SweepProfile.sweep_modes` accepts `"mtr"`; add `mtr_protocol` /
`mtr_max_hops` profile options. The sweep-config compiler passes `mtr` (and
options) into the compiled `AgentCheckConfig`/sweep config so the agent's
`MultiSweepService` runs MTR on the profile's interval. MTR options default
sensibly (`icmp` protocol, 30 hops) when omitted.

### D5: Settings UI
The sweep-profile editor LiveView gains an MTR mode toggle beside ICMP/TCP and
MTR protocol / max-hops inputs, gated by the existing sweep-profile
permissions. No new RBAC.

## Risks / Trade-offs

- **MTR cost in a scheduled sweep.** MTR per target is seconds; a large CIDR
  with MTR enabled is expensive. Mitigated by the bounded MTR worker pool and
  by MTR being opt-in per profile. Document the cost in the UI.
- **Pipeline switch coverage.** Several files switch on `SweepMode`; missing a
  `ModeMTR` arm would silently drop MTR from a code path. Enumerate them (D2)
  and add tests that a mixed `[icmp,tcp,mtr]` sweep yields all three in
  `HostResult`.
- **Not retiring the MTR checker.** This change adds MTR to the sweep engine
  but leaves the standalone `check_type:mtr` checker running. Fully routing all
  MTR through the sweep engine (and retiring the checker + on-demand
  `mtr.run`/`mtr.bulk_run`) is the #4669 follow-on; doing it here would balloon
  scope and risk the existing MTR automation.

## Out of scope

- Retiring the standalone MTR checker / MTR automation (#4669 follow-on).
- Ad-hoc scan MTR (already shipped in `add-adhoc-network-scan`).
