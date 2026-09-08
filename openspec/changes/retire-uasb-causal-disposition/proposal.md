# Retire UASB; reframe anomaly disposition as detector → conditional baseline → causal

## Why

The anomaly engine accreted an overclaimed centerpiece — **UASB ("Uncertainty-Aware
Shrinkage Band")**. Honest accounting:

- **The name is coined, not a methodology.** There is no paper; "shrinkage" is a misnomer
  (`min(s_cell, CAP·s_prior)` is a *clamp*, not statistical shrinkage); "uncertainty-aware"
  is aspirational (`1 + A/√n` mimics a standard error but quantifies nothing — no posterior,
  no coverage); most of the "8 invariants" are safety defaults rather than invariants —
  *though a couple (the poison-bound clamp `min(s_cell, CAP·s_prior)`, the decay-not-reset
  confirm counter) are genuine, test-backed correctness properties.* UASB was a **correct
  detector in an aspirational costume**: the engineering was not broken, the framing was.
- **It is not causal.** The decision is a ~25-line pure function over SQL summaries that uses
  nothing from DeepCausality — no context, no other series, no cause. Hosting it in
  `CausalFlow` is cosmetic.
- **It solves a self-inflicted problem.** "We need 6 weeks for a baseline" only exists inside
  the statistical frame. The band was an elaborate apparatus to suppress recurring-normal
  spikes from few samples.

A survey of the **real** ServiceRadar data fabric (five readers over telemetry / host /
topology / flows / context) inverted the assumed problem. The causes of recurring-but-normal
spikes are **mostly already observable**:

| Spike | Cause | Observable today? |
|---|---|---|
| host CPU/mem | which process consumes | ✅ `sysmon.process` (pid+name+cpu+mem per PID) |
| interface traffic | top-talker / port / peer | ✅ netflow (🟡 rollups fleet-wide, no `if_index`) |
| interface vs. capacity | the link + headroom | ✅ AGE graph `CONNECTS_TO`, `flow_bps`/`capacity_bps` |
| counter-reset artifact | agent/device restart | ✅ `metadata.reset_anchor` (already handled) |
| scan-induced | the agent's own sweep | ✅ `sweep.sequence`, `sweep_group_executions` |
| diurnal | time-of-day driver | ✅ timestamp (🟡 no local TZ) |
| scheduled job / backup | external host schedule | ❌ no maintenance/change registry |

**The real blocker is not missing data — it is missing wiring.** The disposition kernels carry
**only config thresholds** in their `Context` (`anomaly-core` `ReasonContext` = baseline/window
+ `n_sigma`; `SeasonalConfig` = thresholds). There is **no channel** for an observable cause to
reach the decision. Widening that channel — DeepCausality's multi-channel **Context** plus the
write-inference-back-into-context loop — is the *opportunity* to make the causal engine
load-bearing. Stated honestly: the cosmetic-`CausalFlow` hosting is **whole-crate** — seasonal and
capacity dispositions wrap it the same way (no causaloid / reason / CausalArrow) — so widening the
Context is necessary but **not sufficient**, and tier-3 must **earn** the non-cosmetic use with an
actual causal structure. This proposal *poses* that; it does not yet design it.

## What changes

1. **Retire UASB as a methodology/brand.** Remove UASB-named artifacts and the `:peak` NIF ABI
   unless/until a real kernel boundary is designed; strip "UASB" / "uncertainty-aware" /
   "shrinkage band" language from code, docs, and memory. Do **not** discard the useful mechanics
   that fell out of the investigation: matched-resolution peak context, robust percentiles,
   per-series scale/prior, latest-bucket exclusion, safety-biased pass-through, report-only
   calibration, and leaky-bucket confirmation.

2. **Adopt three honest tiers:**
   - **Detector** (have it) — robust per-series deviation, **cause-agnostic** (a novel anomaly has
     no known cause, so detection must not require one). Keep the robust estimators; drop the
     methodology framing.
   - **Conditional baseline** (have it — seasonal residual-z) — "normal *for this series at this
     local time*." One additive: **per-device timezone** so hour-of-day means local.
   - **Causal disposition** (the new work) — widen the kernel `Context` to carry the cause signals
     that already exist (process names, top-talkers, link capacity, reset/scan flags), and write
     dispositions back into context. This is Marvin's lane; this proposal poses it, it does not
     fully specify it.

3. **Additive-schema shortlist** (additive evolution is agreed-safe), by leverage: (a) the
   `Context` channel into the kernel; (b) `if_index`-keyed flow rollups; (c) per-device timezone;
   (d) a change/maintenance/job-window event stream; (e) per-process **network throughput** rolled
   up from netprobe's existing eBPF flow attribution (`bytes`/`packets` already attributed to
   pid/comm — a rollup, not new collection) + per-process **disk I/O** (only disk capacity today).

## Impact

- Affected specs: `observability-signals` (detection-vs-disposition split, cause-context channel,
  honest-naming).
- **Supersession & deps:** this **withdraws** the UASB peak-disposition requirement that
  `add-anomaly-finding-disposition` (#4280, still Open/HELD) would have added — that requirement was
  never archived into the baseline, so this is a *withdrawal*, not a `## REMOVED` block; #4280's
  UASB content should be closed out. Relates to #4288 (the stale-resolve sweep that referenced the
  peak disposition) and #4289 / `align-edge-anomaly-series-key` (the series-key precondition). #4280
  should be resolved/archived in coordination so no orphaned peak requirement is left dangling.
- Affected code: `rust/causal-disposition` (no UASB-branded peak kernel), `rust/srql` (peak profile
  is allowed only as honestly named matched-resolution context), `causal_disposition_nif` (no
  `:peak` ABI until the kernel boundary is settled), plus the forward Context-wiring work. The
  detector and the conditional baseline are unchanged.
- Memory/docs: strip the overclaim; this proposal is the design of record.
- No data migration. The additive fields are forward-only.
