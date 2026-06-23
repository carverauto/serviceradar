# Design — anomaly finding disposition

## Context

Two detectors exist and run today:

- **Edge (recall):** `rust/anomaly-addon` + `rust/anomaly-core` on `serviceradar-agent`. Per-series rolling z-score over a short window of SNMP + sysmon samples; the current tree emits one `Open` on a confirmed transition and one `Clear` (`engine.rs:396-430`). Sub-minute resolution.
- **Central (precision):** `seasonal_disposition/worker.ex` rebuilds a 168-bucket hour-of-week baseline from the **hourly** continuous aggregates (`source.ex:152` via `stats:profile_hour_of_week(value)`), classifies the latest hourly bucket, and emits its own `class_uid=2004` verdict tagged `verdict_source="central-seasonal"`. Hourly resolution.

The edge finding already carries a stable `series_key`, `metric_class`, `device_uid`, score, reason, and time window. The central tier rebuilds history independently from CNPG, so **the edge collapsing a window into a finding does not starve the core** — the raw history is always available. The missing pieces are (a) a step that *joins* the two and produces a disposition, and (b) a decision about *what resolution* that disposition is even valid at.

## THE CENTRAL DESIGN QUESTION: at what resolution does disposition operate?

The edge detects a sub-minute peak. The seasonal tier reasons over an hourly mean. **These are different physical quantities.** A real 30s spike is invisible in (or heavily diluted by) the hour's average, so a seasonal "this hour is normal" verdict does **not** imply "that spike was expected." Any disposition design must pick how to handle that mismatch. This is the hinge of the proposal.

### Option A — Reconcile only where resolutions are comparable (RECOMMENDED for V1)

Keep the two resolutions separate and **forbid the unsound quadrant**. Disposition acts only where it is defensible:

| edge | central-seasonal (hourly) | disposition |
|---|---|---|
| spike | off-baseline (hour also elevated) | **escalate** — sustained, off-profile |
| spike | expected (hour normal) | **pass-through, do NOT suppress** — could be a real short spike the hour hides |
| spike | insufficient baseline (cold start) | **pass-through** |
| no edge | off-baseline (hour elevated, no spike) | **surface** a low-grade "sustained drift" finding |

- **Pros:** small, additive, statistically honest. Never silences a real spike on hourly evidence. Matches the data that actually exists.
- **Cons:** does not reduce the *spike* finding count via seasonal — spike volume is controlled by the edge transition gate + severity calibration, not by seasonal. Seasonal only improves precision on **sustained** regimes and adds the "quiet-but-drifting" detection.
- **Net:** the user's "core decides real-vs-seasonal" is delivered for **sustained** conditions; short spikes remain edge-governed (correct).

### Option B — Make the core dispose the spike apples-to-apples (UPGRADE PATH)

Have the edge forward the **peak magnitude + the spike window** (it already knows them), and give the core a **resolution-matched baseline** — e.g. a peak/percentile profile per hour-of-week (max or p95 per `(series, dow, hod)`), not just the mean — so the core can judge *this spike* against *what spikes that series normally has at this hour*.

- **Pros:** the only way "the core judges the spike itself" is sound. Enables suppressing genuinely-recurring spikes (e.g. a nightly backup that always pins CPU for 40s).
- **Cons:** new SRQL stat (`profile_hour_of_week_p95`/`_max`), a new CAGG or aggregate, more baseline data per cell, and a heavier edge payload. Larger change; needs its own validation that the peak profile is stable.

### Recommendation

Ship **Option A** now (it is additive and never unsound), and treat **Option B** as a follow-on enabled per-metric-class only after the peak profile is proven stable. The proposal's spec encodes Option A's quadrant table as the V1 contract and records Option B as an explicit, scoped extension point. **Reviewers: this choice is the decision to ratify.**

## Disposition layer — where and how

- **Location: alert/query layer, NOT write-time.** The raw edge finding is always persisted (recall + audit). Disposition is computed when an alert is considered and when the device-detail panel renders. Write-time gating is rejected: it couples ingestion to an 8-week-baseline worker, destroys cold-start recall, and loses the audit trail.
- **Join key:** canonical `series_key` + overlapping time window. `fix-anomaly` F4/F14 canonical re-key (`causal_signals.ex:1410`) is the precondition; this change **adds a test asserting edge `series_key` == central `series_key` after re-key** — today that alignment is asserted only in an `addon.rs` comment and is unproven. If the key cannot be proven to align, disposition cannot fire, so this test is load-bearing.
- **Seasonal must emit a verdict for every evaluated series**, not only `{:seasonal_breach}`/qualified `:suppress` (`worker.ex:534` `surfaces?/3`). Today the common "seasonally normal" case emits nothing, so there is nothing to join even if the join existed. Add a non-surfacing `:normal` disposition record (cheap, keyed by series+window) the join can read.
- **Consumers:** `stateful_alert_engine.ex` learns `verdict_source` and applies the quadrant table before opening an alert; the web-ng device-detail panel shows the disposition (suppressed/downgraded/escalated/pass-through) instead of raw severity.

## Soundness + liveness (must precede trusting any disposition)

1. **Robust statistic:** switch the three default seasonal sources to `:median_mad` (`source.ex:82,103,116`). The shipped `:mean_stddev` violates the design's own anti-poisoning guardrail; with a 4–5 sample cell a single past incident hides itself.
2. **NIF liveness gate:** `worker.ex:341-356` wraps `dispose_batch` in `rescue → {:error}` and `classify/1` maps `{:error}` to dropped — a missing/retired `causal_reasoner_nif` makes the whole seasonal tier silently emit nothing, indistinguishable from "all normal." Add a startup/health assertion that the live `dispose_batch` is the real one, surfaced as a degraded-mode signal, not a silent zero.
3. **Cold-start is the steady state, not a transient.** The kernel gate (`baseline.rs:47-48`) needs `min_bucket_samples` (default 4) per `(dow,hod)` cell, i.e. ~5 weeks of history *per cell*. On a 23-device demo most cells never reach it, so `:insufficient_seasonal_baseline` → pass-through must be the dominant, expected path. Disposition coverage must be reported (how many series are seasonally covered) so "seasonal is working" is measured, not assumed.

## Metric-class scope (stop the category overreach)

- **Seasonal tier:** sustained host metrics (`cpu`, `mem` usage). These have meaningful hour-of-week structure.
- **`disk usage_percent`:** near-monotonic (ramp-then-reset) → route to the **capacity forecaster** (Tier B), not seasonal; an hour-of-week mean is close to meaningless for a slow fill.
- **SNMP interface / sysmon counters (the flood sources):** **edge-only**, governed by the transition gate + severity calibration. No seasonal coverage is claimed; disposition for these is "pass-through with calibrated severity."

## Non-edge flood completion (distinct multipliers, same 2004 bucket)

- **capacity_forecasting `event_id` idempotency:** stop splicing per-run wall-clock into the id so the `(id, time)` upsert dedups re-runs (~425k/week). This is independent of the edge fix and must be tracked so "we deployed the edge gate" is not mistaken for "the 2004 flood is gone."
- **Severity calibration:** map the raw z/deviation score onto bounded OCSF severity buckets so undisposed/cold-start findings are not ~77% Critical. Calibration is a pure transform; it does not change recall.
- **Core-side `(device, series_key)` debounce:** belt-and-suspenders behind the edge gate — collapse repeats of an ongoing condition into one open finding with updated state. The existing `(id, time)` upsert cannot catch distinct-timestamp per-slot emission *by construction*, so this is the only core-side guard if an edge regresses.

## Risks

- **Key misalignment** between edge and central `series_key` makes the join silently no-op → covered by the mandated alignment test.
- **Choosing Option B prematurely** before the peak profile is validated would suppress real spikes → Option B is gated per-metric-class behind stability evidence.
- **Declaring the flood fixed after the edge deploy** while capacity_forecasting still emits ~425k/week → tracked as a separate task with its own metric.
- **Trusting seasonal while the NIF is the retired one** → liveness gate makes it loud.
