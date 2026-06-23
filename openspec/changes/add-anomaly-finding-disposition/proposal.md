# Add anomaly finding disposition (edge↔central correlation + resolution model)

## Why

`fix-anomaly-engine-semantics-and-delivery` fixes how anomaly findings are *produced and delivered* (edge transition gating, canonical re-keying F4/F14, seasonal data feed F15). It does **not** decide how a finding is *judged real vs seasonal*, and a deep review of the live system + current tree surfaced three gaps that survive that change:

1. **The disposition loop is never closed.** The seasonal worker `INSERT`s its own parallel `class_uid=2004` verdict tagged `verdict_source="central-seasonal"` (`verdict_emitter.ex`) and **never reads, annotates, or suppresses the edge finding**. Nothing in the alert engine or web-ng joins the two. So the architecture as wired is "two independent detectors," not "edge detects → core disposes." The question *"is this specific finding real or just seasonal?"* is never answered for any specific row — verified: `stateful_alert_engine.ex` has zero references to `seasonal`/`verdict_source`. (`fix-anomaly` F14 establishes the *key* can align; it does not build the join or the disposition.)

2. **The two tiers measure different physical quantities (the central, undecided design question).** The edge fires on **sub-minute spikes**; the seasonal tier scores the **hourly continuous-aggregate mean** (`timeseries_metrics.rs:978`, `DISTINCT ON series ORDER BY bucket DESC`). A 30s 99%-CPU spike averaged into a 1h bucket sitting at 12% is *seasonally normal* while the edge screams. Using the hourly-mean seasonal verdict to keep/drop a short edge spike is therefore **statistically unsound**, and no existing proposal resolves which resolution disposition operates at.

3. **Soundness + scope defects in the seasonal tier itself.** The three default seasonal sources ship `robust_statistic: :mean_stddev` (`source.ex:82,103,116`), but the design mandates `median+MAD` so a past incident hour does not poison the profile (`add-causal-anomaly-detection/design.md:151,242`). And the seasonal sources cover `cpu/mem/disk usage_percent` only — **not** the SNMP interface/sysmon series that dominate the flood — so "seasonal disposes the flood" is a category overreach.

Separately, two **non-edge** flood drivers in the same `class_uid=2004` bucket are not addressed by the edge gate and must not be mistaken for "fixed" after the edge deploy:
- **capacity_forecasting duplicate-per-run** (~2,528/hr ≈ 425k/week): per-run wall-clock is spliced into the `event_id`, defeating the `(id, time)` upsert dedup.
- **Uncalibrated severity**: raw z/deviation scores (12 … 92,554) → ~77% Critical, making undisposed/cold-start noise look like an emergency.

This proposal decides the resolution model and builds the disposition layer correctly on top of it.

## What Changes

- **DECIDE the finding resolution model** (the central design question; see `design.md`): does disposition reconcile only where resolutions are comparable (edge spike vs hourly seasonal stay separate; seasonal never suppresses a short spike), or does the edge forward peak-magnitude + window so the core can dispose the spike apples-to-apples? The proposal recommends the former for V1 and specifies the latter as the upgrade path.
- **Close the disposition loop at the alert/query layer** (not write-time): a correlation step that joins an edge-spike finding to the overlapping central-seasonal verdict by canonical `series_key` + time window and emits a **disposition** (suppress / downgrade / escalate / pass-through) consumed by the alert engine and the device-detail panel. Raw edge findings are retained for audit.
- **Make seasonal disposition emit for every evaluated series** (not only on breach/suppress) so there is a verdict to join, and **gate it on the live `dispose_batch` NIF** so a retired/missing NIF fails loud, not silently-empty.
- **Correct the seasonal statistic + scope**: default to `median+MAD`; scope seasonal to sustained host metrics; route `disk usage_percent` to the capacity forecaster; treat SNMP/interface series as edge-only with calibrated severity (no seasonal coverage claim).
- **Fix capacity_forecasting `event_id` idempotency** and **add severity calibration** for `class_uid=2004` findings.
- **Add a core-side per-`(device, series_key)` debounce** as a safety net so a future edge regression to per-sample emission is absorbed, not re-flooded.

## Impact

- Affected specs: `observability-signals` (ADDED disposition-correlation, resolution-model, robust-statistic, severity-calibration, capacity idempotency requirements).
- Affected code: `seasonal_disposition/{worker,source,verdict_emitter}.ex`, `event_writer/processors/causal_signals.ex`, `stateful_alert_engine.ex`, `web-ng` device-detail anomaly panel, the capacity-forecast event_id builder, `rust/srql` (only if Option B resolution is chosen).
- Depends on: `fix-anomaly-engine-semantics-and-delivery` (edge transition gate deployed; F4/F14 canonical re-key; F15 `profile_hour_of_week`). This change is sequenced **after** that one deploys.
- Non-goal: re-architecting the edge detector or the metrics pipeline. The edge already forwards enough for correlation; the data the core needs (hourly CAGGs) already exists.
