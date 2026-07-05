# Design — anomaly finding disposition

## Context

Two detectors exist and run today:

- **Edge (recall):** `rust/anomaly-addon` + `rust/anomaly-core` on `serviceradar-agent`. Per-series rolling z-score over a short window of SNMP + sysmon samples; the current tree emits one `Open` on a confirmed transition and one `Clear` (`engine.rs:396-430`). Sub-minute resolution.
- **Central (precision):** `seasonal_disposition/worker.ex` rebuilds a 168-bucket hour-of-week baseline from the **hourly** continuous aggregates (`source.ex:152` via `stats:profile_hour_of_week(value)`), classifies the latest hourly bucket, and emits its own `class_uid=2004` verdict tagged `verdict_source="central-seasonal"`. Hourly resolution.

The edge finding already carries a stable `series_key`, `metric_class`, `device_uid`, score, reason, and time window. The central tier rebuilds history independently from CNPG, so **the edge collapsing a window into a finding does not starve the core** — the raw history is always available. The missing pieces are (a) a step that *joins* the two and produces a disposition, and (b) a decision about *what resolution* that disposition is even valid at.

## THE CENTRAL DESIGN QUESTION: at what resolution does disposition operate?

The edge detects a sub-minute peak. The seasonal tier reasons over an hourly mean. **These are different physical quantities.** A real 30s spike is invisible in (or heavily diluted by) the hour's average, so a seasonal "this hour is normal" verdict does **not** imply "that spike was expected." Any disposition design must pick how to handle that mismatch. This is the hinge of the proposal.

### Option A — Reconcile only where resolutions are comparable (simpler alternative — NOT chosen)

Keep the two resolutions separate and forbid suppressing a short spike on hourly evidence; disposition acts only on sustained conditions, short spikes stay edge-governed.

- **Pros:** small, additive, never unsound on existing data.
- **Cons:** does **not** let the core judge the spike itself — a genuinely recurring spike (nightly backup pinning CPU for 40s) still floods because seasonal can never say "that spike is expected." Delivers "real-vs-seasonal" only for sustained regimes.
- **Rejected** because it leaves the spike stream entirely edge-governed; it cannot reduce recurring-spike noise, which is the user's actual goal.

### Option B — Core disposes the spike apples-to-apples (CHOSEN)

Make disposition operate at **matched resolution**: the edge forwards the **peak magnitude + the spike window** (it already computes both), and the core builds a **resolution-matched peak profile** so it can judge *this spike* against *what spikes that series normally produces at this hour-of-week*.

**Peak profile — data already exists.** The hourly CAGG `timeseries_metrics_hourly` already materializes `max_value` per `(series, hour)` (verified on demo: columns `avg_value, min_value, max_value, sample_count`). The peak profile is a **robust aggregate of `max_value` per `(series, hod)` cell** (median center + a robust `(p95−p05)·0.30398` scale over weeks of per-hour maxima — IQR-based, not MAD; see the "Cell granularity" / "decision rule" sections below) — i.e. "the typical peak this series hits in this hour-of-day." No new CAGG or schema change; `max_value` captures the spike (unlike `avg_value`, which dilutes it). This is the resolution match: spike-peak judged against spike-peak history.

**Two profiles, two phenomena.** The core keeps both:
- **Peak profile** (robust aggregate of `max_value`) → judges an **edge spike** (does this peak exceed the series' normal hour-of-week peak?).
- **Mean profile** (robust aggregate of `avg_value`, the existing `profile_hour_of_week`) → judges a **sustained regime** (is the hourly average off-baseline without a spike?).

**Disposition quadrants (V1 contract):**

| edge | matched seasonal verdict | disposition |
|---|---|---|
| spike | peak **above** normal hour-of-week peak (peak profile) | **escalate** — novel/off-profile spike |
| spike | peak **within** normal hour-of-week peak (recurring) | **suppress/downgrade** — seasonally-expected spike |
| spike | insufficient peak history (cold start) | **pass-through** |
| no edge | hourly **mean** off-baseline (mean profile) | **surface** a low-grade sustained-drift finding |

- **Pros:** the only sound way "the core judges the spike." Suppresses genuinely-recurring spikes; escalates novel ones. Directly cuts recurring-spike noise.
- **Cons:** needs a new SRQL stat (a peak variant of `profile_hour_of_week` over `max_value`), a heavier edge payload (peak + window), and per-cell peak-history depth before the peak profile is trustworthy → gated per metric class behind a stability check.

### Decision: Option B (ratified)

Build the matched-resolution peak disposition. Roll it out **per metric class, gated** behind a peak-profile stability check (a class stays in pass-through until its peak profile has enough per-cell history and low run-to-run variance). Cold-start and uncovered classes fall through to edge-governed pass-through, so B is never *less* safe than A during ramp-up — it only adds suppression once the peak profile is trustworthy. The spec encodes the Option B quadrant table as the contract.

**Why B does not violate "ship the cheap version first."** An independent review of the pre-decision draft ratified Option A on the sound principle: *don't build the heavier apples-to-apples machinery until the cheaper honest version proves insufficient*. Two facts make B the better call **without** violating that principle:

1. **B is not actually heavy machinery.** The peak data already exists — `timeseries_metrics_hourly.max_value` is materialized today (verified on demo). B is therefore a peak *variant* of the already-implemented `profile_hour_of_week` stat over `max_value`, plus a small edge payload (peak + window the detector already computes). No new CAGG, no schema change. The cost premise behind "do A first" is largely absent.
2. **B's ramp-up behavior IS Option A.** The per-class stability gate means every class sits in edge-governed **pass-through — i.e. exactly Option A's behavior (never suppress a spike on insufficient evidence)** — until that class's peak profile earns suppression. So B *subsumes* A: A's never-unsound behavior is delivered immediately, and B's recurring-spike suppression activates automatically per class as the data matures, in **one gated mechanism** rather than two sequenced proposals. The reviewer's "prove A isn't enough first" step is built into the gate, not skipped — a class only graduates out of A-equivalent pass-through when its own data proves the peak profile is trustworthy.

The remaining decision is therefore not "A vs B" but "build the gate once now, or ship A and add the gate later" — and since A can *never* reduce recurring-spike noise (the actual goal) and the peak data is already present, building the gate now is the lower-total-cost path.

## Disposition layer — where and how

- **Location: alert/query layer, NOT write-time.** The raw edge finding is always persisted (recall + audit). Disposition is computed when an alert is considered and when the device-detail panel renders. Write-time gating is rejected: it couples ingestion to an 8-week-baseline worker, destroys cold-start recall, and loses the audit trail.
- **Join key:** canonical `series_key` + overlapping time window. `fix-anomaly` F4/F14 canonical re-key (`causal_signals.ex:1410`) is the precondition; this change **adds a test asserting edge `series_key` == central `series_key` after re-key** — today that alignment is asserted only in an `addon.rs` comment and is unproven. If the key cannot be proven to align, disposition cannot fire, so this test is load-bearing.
- **Seasonal must emit a verdict for every evaluated series**, not only `{:seasonal_breach}`/qualified `:suppress` (`worker.ex:534` `surfaces?/3`). Today the common "seasonally normal" case emits nothing, so there is nothing to join even if the join existed. Add a non-surfacing `:normal` disposition record (cheap, keyed by series+window) the join can read.
- **Consumers:** `stateful_alert_engine.ex` learns `verdict_source` and applies the quadrant table before opening an alert; the web-ng device-detail panel shows the disposition (suppressed/downgraded/escalated/pass-through) instead of raw severity.

## Soundness + liveness (must precede trusting any disposition)

1. **Robust statistic:** switch the three default seasonal sources to `:median_mad` (`source.ex:82,103,116`). The shipped `:mean_stddev` violates the design's own anti-poisoning guardrail; with a 4–5 sample cell a single past incident hides itself.
2. **NIF liveness gate:** `worker.ex:341-356` wraps `dispose_batch` in `rescue → {:error}` and `classify/1` maps `{:error}` to dropped — a missing/retired `causal_reasoner_nif` makes the whole seasonal tier silently emit nothing, indistinguishable from "all normal." Add a startup/health assertion that the live `dispose_batch` is the real one, surfaced as a degraded-mode signal, not a silent zero.
3. **Cold-start is the steady state, not a transient.** The kernel gate (`baseline.rs:47-48`) needs `min_bucket_samples` (default 4) per `(dow,hod)` cell, i.e. ~5 weeks of history *per cell*. On a 23-device demo most cells never reach it, so `:insufficient_seasonal_baseline` → pass-through must be the dominant, expected path. Disposition coverage must be reported (how many series are seasonally covered) so "seasonal is working" is measured, not assumed.

## Metric-class scope

Coverage depends on whether a meaningful hour-of-week **peak** profile exists for the series:

- **Utilization / rate series (`cpu`, `mem`, interface utilization %):** covered by both the **peak profile** (spike disposition) and the **mean profile** (sustained drift). Critically, the SNMP interface / sysmon utilization series that dominate the flood **are coverable here** once their peak profile is stable — this is the payoff of Option B over A, which could only ever leave them edge-only.
- **`disk usage_percent`:** near-monotonic (ramp-then-reset) → route to the **capacity forecaster** (Tier B); neither an hour-of-week mean nor peak is meaningful for a slow fill.
- **Raw non-normalized counters (e.g. absolute `ifInOctets`):** no meaningful "normal peak" → edge-only + severity calibration until rate-normalized into a utilization series.
- A spike stays in **pass-through** until its own `(series, dow, hod)` cell passes the **stability gate** (concrete criteria below), so coverage ramps safely per cell — a class with no stable cells is simply all-pass-through.

## Robust peak-profile stability gate

Suppression silences a finding, so a **false-suppress hides a real anomaly** — strictly worse than a false-surface. This asymmetry is the north star: every uncertain path must decay toward **pass-through or escalate, never toward suppress**. Replacing the original hard "inert for 6 weeks" cliff, the gate is a continuous band that ramps as the cell's sample count `n` grows. Its form was hardened over **two adversarial-verification rounds** that refuted (a) a one-sided band that silenced every downward anomaly, (b) an additive raw floor that blinded tight series, and (c) a prior pooled across hours that let a spiky hour whitewash its neighbors. What survives is a set of **invariants** plus a decision rule whose constants are implementation-calibrated.

### Cell granularity: `(series, hod)`; prior is per-series (series-overall)
Live data is decisive: per-`(series, dow, hod)` cells are frozen at n=1 (max 2) for ~6 weeks, but **`(series, hod)` cells reach median n=8 (93% ≥ 6) within a *week*** — DOW adds ~nothing (median |weekday−weekend| ≈ 0–1.5pp) while hour-of-day carries the signal. So the **cell** is **`(series, hod)`** (collapse only DOW) and is never pooled across `hod`.

The **prior** (the I2 min-cap reference) is the **per-series, series-overall robust scale**. This changed during calibration: the design first reached for a `(series,hod)`/`(hod)`-class prior, but on real fleet data the `(hod)`-class prior is ≈ 30 (it pools idle + saturated series), so for an idle series (normal scale ≈ 0.5) the `CAP·s_pri = 2·30 = 60` cap never binds — a poisoned cell could inflate 120× before the bound engages, defeating I2. The series-overall scale bounds each series by ~`CAP×` *its own* variability (idle bound ≈ 1.1), so the poison-resistance actually works. Pooling the prior across `hod` is intentional and safe here: it is a `min`-cap bound, **not** the band center/width, so it cannot smear a spiky hour into a quiet one (the quiet hour's tight `s_cell` always wins the `min`).

### The decision rule (O(1) scalar; robust stats only)
From SQL per cell: `n`, robust center `c = median`, robust scale `s_cell = (p95−p05)·0.30398`, the **per-series** prior scale `s_pri`, and `q95`. Given spike peak `p`:
- **Two-sided** bands: inner (suppress) `c ± Z_sup·s_inner·k_n`; outer (escalate) `c ± Z_esc·s_outer·k_n`.
- **Sigma-relative low-n inflation** `k_n = 1 + A/√n` (→1 as n→∞) — widens with the series' *own* scale, so a tight series stays tight; no additive raw floor.
- **Inner band scale bounded ABOVE by the per-series prior** (the load-bearing poison-resistance fix): `s_inner = min(s_cell, CAP·s_pri)` — a poisoned/thin cell cannot inflate the *suppression* region beyond what the series' own typical scale justifies. The outer band uses `s_outer = max(s_cell, s_pri)` (wider escalation is safe).
- **Guards → pass-through (never suppress):** cold (`n < N_min`); over-dispersed (`s_cell > D·s_pri` → cell looks poisoned vs its own class); ceiling-proximity (`q95 + Z_sup·s_inner·k_n ≥ 100` → no upward headroom to discriminate); degenerate scale floored at a tiny absolute (0.5pp) only when `s ≈ 0`.
- **Decision:** suppress iff `p` inside the inner band; escalate iff `p` outside the outer band (either side); else downgrade. **A suppress verdict does NOT reset the confirm-slot counter** (else a real recurring anomaly sticks suppressed).

### Invariants (THESE are the spec; constants are calibration)
Each is provable by the adversarial test that established it:
1. **Two-sided** — a downward real anomaly escalates, never auto-suppressed.
2. **Poison-bounded inner band** — a minority of poisoned samples cannot widen the suppression band beyond `CAP·prior`; a real novel spike still escalates.
3. **Per-series prior, `(series,hod)` cell** — the cell (band center/width) is never pooled across `hod`, so a quiet-hour novel spike is not suppressed by a spiky neighbor-hour's scale; the prior is the series-overall min-cap bound (pooling it across `hod` cannot smear, since `min` keeps the quiet hour's tight scale).
4. **Ceiling-proximity guard** — a tight near-100% cell passes through (never a >100% band).
5. **Over-dispersion guard** — a cell anomalously dispersed vs its class passes through.
6. **Cold pass-through** — suppression off until `n ≥ N_min`.
7. **Non-sticky** — suppress does not reset the confirm-slot counter.
8. **Asymmetry** — every uncertain path resolves to pass-through or escalate, never suppress.

### Ramp behavior
n=1–3 (`(series,hod)` cold) → pass-through (a real 6-σ excursion on a tight series is NOT suppressed). By ~day 5–week 1 (n≥4–8) the band binds — recurring-normal peaks suppress, novel ones escalate. By n≈26–52 the inflation is negligible and the band is the cell's own tight two-sided envelope. Smooth, no cliff — usable in ~1 week, not 6.

### Operational controls + calibration
- Per-metric-class **kill switch** (default on); ships with suppression **disabled (report-only)** until constants are calibrated.
- **Coverage metric** = suppression-*eligible mass* (fraction of `(series,hod)` cells that are `!cold && !saturated && !over_dispersed`, and the suppressed fraction within) — observable ramp, not binary.
- Safe a priori: the invariants, the two-sided form, `(series,hod)` locality. Calibration-required against real per-cell distributions (guarded by the invariant test suite): `A, Z_sup, Z_esc, CAP, N_min, D`, saturation thresholds.

### Implementation substrate (re: DeepCausality)
The peak-profile decision belongs on the same DeepCausality substrate as the edge detector
(`anomaly-core` `CausalFlow`) and the seasonal/capacity dispositions. It is **not** an
`Uncertain<T>` or Monte-Carlo path: the hot path is an **O(1) deterministic decision** over
SQL-precomputed robust summaries, and robustness is an **estimator** property (median center,
robust `(p95-p05)` scale, bounded inner band, and safety invariants), not a sampling-framework
feature. If/when this becomes a true causal disposition, the peak profile should enter as one
context signal alongside process, flow, topology, reset, and scan context — not as a branded
standalone methodology.

## Non-edge flood drivers — owned by fix-anomaly (out of scope here)

The other `class_uid=2004` flood drivers are **not** in this proposal: capacity_forecasting `event_id` idempotency (~425k/week) is `fix-anomaly` **F12** (tasks 10.1, 12.4); per-series debounce is **task 23.2**; raw detector→finding/alert severity calibration is **task 23.4**. They ship with that deploy. This proposal owns only **disposition-driven effective severity** (suppress→off-path, downgrade→lower, escalate→higher).

## Risks

- **Key misalignment** between edge and central `series_key` makes the join silently no-op → covered by the mandated alignment test.
- **Choosing Option B prematurely** before the peak profile is validated would suppress real spikes → Option B is gated per-metric-class behind stability evidence.
- **Declaring the flood fixed after the edge deploy** while capacity_forecasting still emits ~425k/week → tracked as a separate task with its own metric.
- **Trusting seasonal while the NIF is the retired one** → liveness gate makes it loud.
