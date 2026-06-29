// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The seasonal disposition kernel: deseasonalized residual-z over the historical
//! hour-of-week profile, on the shared `anomaly-core` `CausalFlow` substrate.
//!
//! # Channel mapping (design D4)
//! - **Value** = [`Disposition`] — the only channel the intervene arm writes.
//! - **State** = [`SeasonalState`] — the `(dow,hod)` bucket accumulators with the
//!   **latest bucket excluded** (the bucket-exclusion invariant, D6), plus the
//!   `consecutive_anomalous` carried in from Postgres.
//! - **Context** = [`SeasonalConfig`] — `{seasonal_n_sigma, min_bucket_samples,
//!   confirm_slots, robust_statistic}`, read-only.
//!
//! The 168-bucket hour-of-week profile aggregation STAYS in SQL (data gravity, D6);
//! this kernel receives one [`SeasonalRow`] per series-under-test carrying the
//! pre-aggregated bucket summary statistics, and moves only the residual-z, breach,
//! baseline-sufficiency gate, and robust-statistic selection.
//!
//! # The bucket-exclusion invariant (D6, graft #2)
//! Because the seasonal baseline is the historical hour-of-week profile (NOT a
//! self-masking sliding window like the rolling detector), the withhold-from-
//! baseline trick does not apply automatically. **The latest complete bucket under
//! test MUST be excluded from the mean/stddev it is scored against** — otherwise a
//! real drift inflates its own baseline and hides. For the mean/stddev statistic
//! this kernel performs the exclusion *algebraically* from the SQL-supplied bucket
//! sums (see [`SeasonalState::excluded_baseline`]). For the robust statistics
//! (median/MAD, p05–p95) the order statistics cannot be de-aggregated by one point,
//! so SQL supplies them already computed over the excluded historical profile; the
//! kernel trusts that contract and asserts it via [`SeasonalRow::baseline_excludes_latest`].

mod baseline;
#[cfg(test)]
mod tests;
mod types;

pub use types::{SeasonalConfig, SeasonalDisposition, SeasonalRow};

use types::{ExcludedBaseline, SeasonalState, SeasonalValue};

use crate::disposition::Disposition;
use deep_causality_core::{CausalFlow, CausalityError, CausalityErrorEnum};

/// Score one seasonal row. The public seam the NIF's per-row loop calls. Always
/// returns a [`SeasonalDisposition`]; gates resolve to a [`Disposition`] variant,
/// never a panic (graft #1).
pub fn dispose_seasonal(row: SeasonalRow, config: &SeasonalConfig) -> SeasonalDisposition {
    let series_key = row.series_key.clone();

    let (disposition, next_consecutive_anomalous, score) = match run_seasonal_flow(row, config) {
        Ok(outcome) => outcome,
        // The flow itself never returns Err in practice (every gate is a Value),
        // but the monadic `finish()` is fallible — degrade to a Skipped value.
        Err(err) => (
            Disposition::Skipped {
                reason: format!("seasonal flow error: {err}"),
            },
            0,
            0.0,
        ),
    };

    SeasonalDisposition {
        series_key,
        disposition,
        next_consecutive_anomalous,
        score,
    }
}

/// Drive the seasonal `CausalFlow`: process state, hydrate the excluded baseline
/// into Context, branch breach/clean, finalize the verdict. Mirrors the
/// `reason_impl` chain in `anomaly-core` (`detector.rs:84-114`).
fn run_seasonal_flow(
    row: SeasonalRow,
    config: &SeasonalConfig,
) -> Result<(Disposition, usize, f64), String> {
    let carried = row.consecutive_anomalous;
    let state = SeasonalState {
        row,
        baseline: None,
    };

    let value = CausalFlow::process(state)
        .context(*config)
        .map(|()| SeasonalValue::Evaluate)
        .update_value_state_context(hydrate_baseline)
        .branch_with(
            |value, _state, _context| {
                // The breach arm: a residual that cleared the threshold.
                matches!(value, SeasonalValue::Disposed(d) if d.surfaces_or_pending())
            },
            |breach| breach,
            |clean| clean,
        )
        .update_value_state_context(finalize_seasonal_verdict)
        .finish()
        .map_err(|err| err.to_string())?;

    let disposition = match value {
        SeasonalValue::Disposed(d) => d,
        SeasonalValue::Evaluate => {
            return Err(CausalityError::new(CausalityErrorEnum::ValueNotAvailable).to_string());
        }
    };

    // Confirm-slot hysteresis: a residual over threshold increments the carried
    // counter; a clean row resets it.
    //
    // The reset on `Suppress` is DELIBERATE and is the correct semantics at this
    // resolution. Seasonal judges the hourly mean: a `Suppress` means the
    // deseasonalized hour genuinely returned to baseline, so the sustained condition
    // really did clear and the pending count should reset.
    let next_consecutive_anomalous = match &disposition {
        Disposition::SeasonalBreach { .. } | Disposition::SeasonalDrift { .. } => {
            carried.saturating_add(1)
        }
        Disposition::Suppress => 0,
        // Gate variants neither confirm nor reset; preserve the carried counter so a
        // transient thin/skip cycle does not erase confirmation progress.
        Disposition::InsufficientSeasonalBaseline | Disposition::Skipped { .. } => carried,
        // Capacity-only Value variants never arise on the seasonal flow (the
        // seasonal kernel only ever produces the variants above), but the enum is
        // shared, so preserve the carried counter for exhaustiveness.
        Disposition::Projected { .. } | Disposition::Inactive => carried,
    };

    let score = disposition.score().unwrap_or(0.0);
    Ok((disposition, next_consecutive_anomalous, score))
}

impl Disposition {
    /// Whether this disposition took the breach arm of the flow (a confirmed breach
    /// OR a pending drift — both cleared the residual threshold).
    fn surfaces_or_pending(&self) -> bool {
        matches!(
            self,
            Disposition::SeasonalBreach { .. } | Disposition::SeasonalDrift { .. }
        )
    }
}

/// Stage 1 of the flow: build the excluded baseline and pre-classify the residual
/// into a [`Disposition`]. Mirrors `evaluate_detector_command` (`detector.rs:203`).
fn hydrate_baseline(
    _value: SeasonalValue,
    mut state: SeasonalState,
    context: Option<SeasonalConfig>,
) -> (SeasonalValue, SeasonalState, Option<SeasonalConfig>) {
    let Some(config) = context.as_ref() else {
        return (
            SeasonalValue::Disposed(Disposition::Skipped {
                reason: "seasonal config missing".to_string(),
            }),
            state,
            context,
        );
    };

    match state.excluded_baseline(config) {
        Ok(baseline) => {
            state.baseline = Some(baseline);
            let score = residual_z(state.row.sample_value, baseline);
            let disposition = if !score.is_finite() {
                Disposition::Skipped {
                    reason: "residual z is non-finite".to_string(),
                }
            } else if score >= config.seasonal_n_sigma {
                // Confirm-slot decision is finalized in stage 2 against the
                // carried counter; here we only mark "over threshold".
                Disposition::SeasonalDrift { score }
            } else {
                Disposition::Suppress
            };
            (SeasonalValue::Disposed(disposition), state, context)
        }
        // Every gate is a value, never an unwind (graft #1).
        Err(gate) => (SeasonalValue::Disposed(gate), state, context),
    }
}

/// Stage 2 of the flow: apply confirm-slot hysteresis to promote a pending drift to
/// a confirmed breach. Mirrors `finalize_detector_verdict` (`detector.rs:281`).
fn finalize_seasonal_verdict(
    value: SeasonalValue,
    state: SeasonalState,
    context: Option<SeasonalConfig>,
) -> (SeasonalValue, SeasonalState, Option<SeasonalConfig>) {
    let SeasonalValue::Disposed(disposition) = value else {
        return (value, state, context);
    };
    let Some(config) = context.as_ref() else {
        return (SeasonalValue::Disposed(disposition), state, context);
    };

    let promoted = match disposition {
        Disposition::SeasonalDrift { score } => {
            // The carried counter plus this slot. confirm_slots == 1 means a single
            // over-threshold bucket confirms immediately.
            let confirmed_slots = state.row.consecutive_anomalous.saturating_add(1);
            if confirmed_slots >= config.confirm_slots.max(1) {
                Disposition::SeasonalBreach { score }
            } else {
                Disposition::SeasonalDrift { score }
            }
        }
        other => other,
    };

    (SeasonalValue::Disposed(promoted), state, context)
}

/// Deseasonalized residual z: `|v - center| / scale` against the excluded
/// baseline. The center/scale are already deseasonalized (the seasonal profile)
/// and exclude the latest bucket (the invariant), so this is a residual z over the
/// historical hour-of-week baseline, not a raw z.
fn residual_z(sample_value: f64, baseline: ExcludedBaseline) -> f64 {
    if baseline.scale <= f64::EPSILON {
        return f64::INFINITY;
    }
    ((sample_value - baseline.center) / baseline.scale).abs()
}
