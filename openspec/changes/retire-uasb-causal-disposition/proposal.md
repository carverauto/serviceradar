# Retire UASB; reframe anomaly disposition as detector → conditional baseline → causal

## Why

The anomaly engine accreted an overclaimed centerpiece — **UASB ("Uncertainty-Aware
Shrinkage Band")**. Honest accounting:

- **The name is coined, not a methodology.** There is no paper; "shrinkage" is a misnomer
  (`min(s_cell, CAP·s_prior)` is a *clamp*, not statistical shrinkage); "uncertainty-aware"
  is aspirational (`1 + A/√n` mimics a standard error but quantifies nothing — no posterior,
  no coverage); the "8 invariants" are safety defaults, not invariants.
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
reach the decision. That is the first non-cosmetic reason to use DeepCausality here: its
multi-channel **Context** (and the write-inference-back-into-context loop) is exactly that channel.

## What changes

1. **Retire UASB.** Remove the peak-disposition kernel (`rust/causal-disposition/.../peak`), the
   `profile_hour_of_week_peak` SRQL stat, and the `:peak` NIF ABI; strip "UASB" /
   "uncertainty-aware" / "shrinkage band" / "8 invariants" language from code, docs, and memory.
   Salvage the one real learning (per-series prior beats class-pooled — see design).

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
- Affected code: `rust/causal-disposition` (remove peak), `rust/srql` (remove peak stat),
  `causal_disposition_nif` (remove `:peak`), plus the forward Context-wiring work. The detector and
  the conditional baseline are unchanged. UASB is `report_only` (inactive), so retirement is
  behaviorally safe.
- Memory/docs: strip the overclaim; this proposal is the design of record.
- No data migration. The additive fields are forward-only.
