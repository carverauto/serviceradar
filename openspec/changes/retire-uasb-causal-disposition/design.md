# Design — tiered anomaly disposition, grounded in the cause-fabric survey

## Two jobs, not one (the distinction UASB collapsed)

- **Detection** — "this series deviated." Cause-agnostic by necessity: a *novel* anomaly has no
  known cause, so the detector must flag a CPU/traffic spike without explaining it. Works on low
  data (a rolling window yields a deviation score from day one). This is statistics, and it is
  fine. ServiceRadar already has it: the edge z-score (`anomaly-core`) with per-class dispersion
  floors + directional saturation gates.
- **Disposition** — "is that deviation normal-recurring, or real?" This is where data-hunger lives
  (you only know a recurrence is normal if you've seen it, or you know what drives it) and where
  *cause* helps. UASB tried to be this layer using a statistics band, and called it causal. Both
  were mistakes; the detector was never the problem.

The detector ships regardless, so the 6-week-baseline pain never blocks *detection* — only the
*suppression* of recurring-normal ramps with data, and the causal tier removes even that wherever
the cause is observable.

## What the cause-fabric survey established

Five read-only readers over the live schema + collectors. The finding inverts UASB's premise:
the causes are mostly **in the fabric already**.

- **Host CPU/mem** → `sysmon.process` carries pid + name + cpu + mem **per process** (demo: spikes
  resolve to `git`/`rustc`/`cc1plus` = CI builds). Per-core (`core_id`, big.LITTLE cluster) too.
  Causally tractable **today**. Gaps: top-N only (no full inventory); network-as-cause is not in
  sysmon (`sysmon.network` off) **but netprobe's eBPF `FlowAttributionEvent` already byte-attributes
  network to pid/comm — derivable as a rollup, no new collection**; disk *I/O* not collected (only
  capacity — add it, ideally eBPF-attributed per process).
- **Interface traffic** → netflow has src/dst, application port, AS/peer, direction → top-talker
  attribution. Gap: hourly rollups aggregate **fleet-wide with no `if_index`**, so per-interface
  attribution must hit the raw flow table; sampling-rate normalization needed to reconcile with the
  SNMP counter magnitude.
- **Interface vs. neighbor/capacity** → AGE graph: interface↔interface `CONNECTS_TO`, device
  adjacency with `flow_bps`/`capacity_bps`, MTR hop paths, directional split. "Normal while
  `flow_bps < capacity_bps`" is queryable. Gap: topology is **point-in-time** (edges overwritten on
  rebuild; no temporal history).
- **Counter-reset / scan / restart artifacts** → `metadata.reset_anchor`, `sweep.sequence`,
  `sweep_group_executions`, service down→up — all observable; reset handling already lives in the
  addon counter logic.
- **Diurnal** → timestamp hour-of-day/day-of-week. Gap: **no local timezone** (UTC only → mis-phased
  for geo-distributed fleets).
- **Scheduled job / backup / patch** → ❌ **not collected.** No maintenance/change/job-schedule
  registry; the cause is only reverse-inferable from process names (lossy). This is the one genuine
  *data* gap, and it is the largest class of recurring-but-normal spikes.

## The architectural disconnect (the headline)

Even where a cause is fully observable, **the disposition kernel cannot see it.** `anomaly-core`
`ReasonContext` is baseline/window stats + `n_sigma`; `SeasonalConfig` is thresholds. The `Context`
channel carries *config*, not *cause*. So the problem is **wiring, not collection, and not
statistics.** Widening that channel to carry the already-observable cause signals (and writing
dispositions back into context for subsequent inference) is precisely DeepCausality's multi-channel
context model — the *opportunity* to make the causal engine load-bearing rather than decorative.

**Honest caveat (do not let this ship as fact):** the decoration is **whole-crate**, not
UASB-specific. Seasonal and capacity dispositions wrap `CausalFlow` identically — `process →
context(config) → update_value_state_context → finish`, with no causaloid, no `reason`, no
`CausalArrow`. So widening the `Context` is *necessary but not sufficient*: tier-3 only becomes
"non-cosmetic" if it grows an actual causal structure over those cause signals. That is a
**direction, not yet a design** — the "where is a cause observable, and how does it enter the
decision" boundary is undefined here and is the work to do with Marvin, not a settled claim.

## Why retire UASB (rather than rename/keep)

- It is redundant: the recurring-normal suppression it targets is done more cleanly by the
  conditional baseline (once warm) and the causal tier (where the cause is known).
- It is overclaimed: the name/"uncertainty-aware"/"invariants" framing misrepresents a heuristic as
  a methodology, which actively costs credibility (a wrong `1+A/√n` rendering, "Rust" as a
  disposition, etc.).
- It risks becoming inert: `report_only`/unwired machinery would be behaviorally safe, but carrying
  a UASB-branded kernel/stat/ABI forward would preserve a misleading design story.

**Salvaged learning (keep this):** matched-resolution peak context is useful when judging an edge
spike; robust percentiles are useful; latest-bucket exclusion is useful; calibration showed the
scale/prior **must be per-series, not class-pooled** — a class prior is ~30× too wide to bound a
poisoned tight series. Generalized, this is real: *a per-series scale is the right normalizer; a
pooled-class scale is not.* Those mechanics survive UASB's retirement and should be described
plainly as robust empirical context, not as a named uncertainty methodology.

## Honest naming (binding)

No component SHALL be labeled "uncertainty-aware" unless it produces a calibrated uncertainty
quantity (posterior / interval with coverage). Robustness is an estimator property, stated plainly,
not a brand.

## Scope boundary

This proposal **retires UASB** and **establishes the tiers + the cause-context channel as the
direction**. It deliberately does **not** fully specify the causal disposition implementation — that
is foundational causal-engine work (Marvin's lane), to be designed against the cause-fabric map
once the `Context` channel exists. The detector and conditional baseline are unchanged code.
