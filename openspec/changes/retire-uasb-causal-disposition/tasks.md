# Tasks — retire UASB; reframe to tiered causal disposition

## 0. Decision / grounding (done)
- [x] 0.1 Cause-fabric survey of the live schema + collectors (5 readers): causes mostly observable; the blocker is the threshold-only kernel `Context` (design.md).
- [x] 0.2 Confirm UASB is `report_only` / inactive → retirement is behaviorally safe.

## 1. Retire UASB (the strip) — follow-up code PR, scoped here
- [ ] 1.1 Remove UASB-branded peak-disposition code/module wiring. A future robust peak disposition may exist, but it must be named honestly and designed against the causal-context boundary.
- [ ] 1.2 Keep `profile_hour_of_week_peak` only if it is framed as matched-resolution peak context; remove any UASB-specific SRQL naming/docs around it.
- [ ] 1.3 Do not expose a `:peak` ABI from `causal_disposition_nif` until the robust peak/cause-context kernel boundary is settled.
- [ ] 1.4 Strip "UASB" / "uncertainty-aware" / "shrinkage band" language from the codebase, the disposition docs, and the DeepCausality-paper framing. Salvage the useful mechanics as plain detector/baseline/context notes.
- [ ] 1.5 Verify build + tests after cleanup; confirm seasonal/capacity dispositions and the edge detector are untouched.

## 2. Conditional baseline (tier 2 — small additive)
- [ ] 2.1 Add per-device **local timezone** so the seasonal hour-of-day/day-of-week profile phases on local business hours, not UTC (additive field + plumb into the seasonal stat).

## 3. Causal disposition (tier 3 — the real direction; design follows, not specified here)
- [ ] 3.1 Widen the disposition kernel `Context` beyond config thresholds to carry observable cause signals: `sysmon.process` top consumers (CPU/mem), netflow top-talker/port (traffic), AGE `flow_bps`/`capacity_bps` (interfaces), `reset_anchor`/`sweep.sequence` (artifacts).
- [ ] 3.2 Establish the write-back loop: a disposition result is written into the context for subsequent inference (DeepCausality multi-channel context). Co-design with Marvin against the cause-fabric map.
- [ ] 3.3 The disposition becomes: deviation (tier 1) + "expected given its observable cause?" (tier 3) → Suppress / Drift / Breach — replacing the band-membership test.

## 4. Additive-schema shortlist (forward-only, by leverage)
- [ ] 4.1 `if_index`-keyed flow rollup (add the interface dimension to talker/port/conversation rollups) → per-interface traffic attribution without scanning raw flows.
- [ ] 4.2 Change/maintenance/job-window event stream (the one genuine data gap — backups, cron, patch windows) joinable on timestamp+agent.
- [ ] 4.3 Per-process **network throughput** as a cause signal — **derive it from netprobe's existing eBPF `FlowAttributionEvent`** (already carries `bytes`+`packets` per flow attributed to a process via `WorkloadIdentity`/pid/comm), rolled up per process, rather than enabling NIC-level `sysmon.network`. Process-attributed network is the richer cause signal and reuses collection already running. Note coverage: netprobe runs where deployed (worker agents) — `sysmon.network` is only a fallback for hosts without netprobe, if needed.
- [ ] 4.4 Add disk **I/O** (only disk *capacity* `used_percent` is collected today). Prefer the same eBPF process-attribution pattern (per-process disk throughput/IOPS) so it's a *cause* signal consistent with 4.3; per-mount sysmon I/O is the simpler fallback.

## 5. Hygiene
- [ ] 5.1 Fix the `sysmon.process` `series_key` cardinality smell: `pid` + `start_time` are folded into the key, so every short-lived process mints a new series (demo: 229→2959 series/hour). Key on `(host, process name)` for the gauge dimensions; carry pid/start_time as non-key metadata.
- [ ] 5.2 Update memory + docs to the reframe (strip the overclaim; record the cause-fabric findings + the Context-channel gap as the design of record).
