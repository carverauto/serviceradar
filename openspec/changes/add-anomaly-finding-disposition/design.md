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

**Peak profile — data already exists.** The hourly CAGG `timeseries_metrics_hourly` already materializes `max_value` per `(series, hour)` (verified on demo: columns `avg_value, min_value, max_value, sample_count`). The peak profile is a **robust aggregate of `max_value` per `(series, dow, hod)` cell** (median + MAD over weeks of per-hour maxima) — i.e. "the typical peak this series hits in this hour-of-week." No new CAGG or schema change; `max_value` captures the spike (unlike `avg_value`, which dilutes it). This is the resolution match: spike-peak judged against spike-peak history.

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

## Peak-profile stability gate (concrete criteria)

Suppression silences a finding, so a false suppress hides a real anomaly — strictly worse than a false surface. The gate is therefore conservative and operates **per `(series, dow, hod)` cell**, not per class: a spike is disposed against the peak profile only if *its own cell* is stable; otherwise it falls through to Option-A pass-through. A class with no stable cells is automatically all-pass-through, so "per-class rollout" needs no separate data gate — it is the emergent result of per-cell graduation.

### A cell is *stable* (eligible for suppression) iff ALL hold
All thresholds are config-defaulted and tunable per deployment.

1. **Depth** — at least `min_cell_weeks` distinct weekly maxima contribute to the cell (default **6**). Each week contributes one observation (the max in that hour-of-week), so this is ~6 weeks of history for that cell. Below it, the cell's median + MAD is not trustworthy → pass-through.
2. **Recency** — the most recent weekly maximum is within `max_cell_staleness_weeks` (default **2**). A series that stopped reporting at that hour-of-week has a stale profile → pass-through.
3. **Bounded dispersion** — `MAD / max(median, ε) ≤ max_cell_dispersion` (default **0.5**, calibrate against real per-cell data). If a series' peaks at that hour-of-week are erratic, "normal range" is not meaningful → pass-through. A near-zero MAD is handled by the floor below, not by failing the gate.

### Disposition when the cell IS stable
Let `m` = cell median peak, `d` = cell MAD, `D = max(d, mad_floor·m)` with `mad_floor` default **0.05** (a 5%-of-median floor so a near-constant cell does not make every deviation look infinite):

| spike peak vs profile | disposition |
|---|---|
| `peak ≤ m + k_suppress·D` (`k_suppress` default **3**) | **suppress** (or downgrade) — within normal hour-of-week peak |
| `m + k_suppress·D < peak ≤ m + k_escalate·D` (`k_escalate` default **6**) | **downgrade** — elevated but not clearly novel |
| `peak > m + k_escalate·D` | **escalate** — novel, off-profile |

The wide `[k_suppress, k_escalate]` band (3→6 MAD) is deliberate: only a clearly-within-normal peak is suppressed, only a clearly-novel peak is escalated, and the ambiguous middle is merely **downgraded (kept visible)**, never silenced.

### Operational controls + calibration
- A per-metric-class **kill switch** (config) disables suppression for a class regardless of cell stability (default: enabled) — for classes known to be spiky-by-nature where suppression is never wanted.
- A **coverage metric** reports, per class, the fraction of active-series cells that are stable, so "is suppression doing anything yet?" is observable, not assumed.
- The depth/recency gates are safe a priori; `max_cell_dispersion`, `k_suppress`, `k_escalate`, and `mad_floor` are data-dependent and SHALL be calibrated against real per-cell peak distributions before suppression is enabled in production (they start as conservative guesses).

## Non-edge flood completion (distinct multipliers, same 2004 bucket)

- **capacity_forecasting `event_id` idempotency:** stop splicing per-run wall-clock into the id so the `(id, time)` upsert dedups re-runs (~425k/week). This is independent of the edge fix and must be tracked so "we deployed the edge gate" is not mistaken for "the 2004 flood is gone."
- **Severity calibration:** map the raw z/deviation score onto bounded OCSF severity buckets so undisposed/cold-start findings are not ~77% Critical. Calibration is a pure transform; it does not change recall.
- **Core-side `(device, series_key)` debounce:** belt-and-suspenders behind the edge gate — collapse repeats of an ongoing condition into one open finding with updated state. The existing `(id, time)` upsert cannot catch distinct-timestamp per-slot emission *by construction*, so this is the only core-side guard if an edge regresses.

## Risks

- **Key misalignment** between edge and central `series_key` makes the join silently no-op → covered by the mandated alignment test.
- **Choosing Option B prematurely** before the peak profile is validated would suppress real spikes → Option B is gated per-metric-class behind stability evidence.
- **Declaring the flood fixed after the edge deploy** while capacity_forecasting still emits ~425k/week → tracked as a separate task with its own metric.
- **Trusting seasonal while the NIF is the retired one** → liveness gate makes it loud.
