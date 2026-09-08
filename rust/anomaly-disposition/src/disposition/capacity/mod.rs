// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The capacity-forecast disposition kernel: a verbatim port of
//! `ServiceRadar.Observability.CapacityForecasting.Model` (`model.ex:1-396`) onto
//! the shared `anomaly-core` `CausalFlow` substrate, mirroring the structure of
//! [`crate::disposition::seasonal`].
//!
//! # Channel mapping (design D4, task 7.1)
//! - **Value** = [`CapacityVerdict`] — the [`Disposition`] extension the intervene
//!   arm writes: [`Disposition::Projected`] (a fit + projection + ETA + bounds),
//!   [`Disposition::Inactive`] (a successful fit whose threshold crossing collapsed
//!   to "no projected exhaustion"), or [`Disposition::Skipped`] (the
//!   `insufficient_history` gate and the non-finite guards — graft #1, never a
//!   panic).
//! - **State** = [`types::CapacityState`] — the fit accumulators: the normalized
//!   `(offset_seconds, value)` points, the least-squares slope/intercept OR the
//!   Holt-Winters level/trend/seasonals, the residuals/RMSE, and the projection
//!   cursor.
//! - **Context** = [`CapacityConfig`] — `{capacity_threshold, horizon_seconds,
//!   model_kind, min_history, period, alpha, beta, gamma, value_min, value_max}`,
//!   read-only.
//!
//! # Parity is the gate (graft #4)
//! With no physical value bounds configured, every numeric output field
//! (`slope_per_second`, `intercept`, `projected_value`, `confidence`,
//! `lower_bound`, `upper_bound`, the exhaustion ETA) must match `model.ex` to
//! within `1e-9`. To that end this port preserves the **exact** summation order,
//! the `@epsilon = 1.0e-9` least-squares denominator guard (`model.ex:14,208`),
//! the `@exhaustion_horizon_multiplier 10` plausibility bound (`model.ex:21`),
//! the `@seasonal_strength_threshold 0.25` autodetect (`model.ex:13,352`), the
//! `1.96 * rmse` band, and the `round(cross_x)` ETA rounding (`model.ex:273`).
//! Bounded configs intentionally clamp only the emitted projection/bands after
//! the raw fit; the ETA remains raw-fit based. See the `RISKS` notes in the
//! module tests and the Elixir golden-fixture parity test for the divergence
//! surface.
//!
//! # Orchestration stays in Elixir (task 7.4)
//! This kernel performs ONLY the numeric forecast compute. The interface
//! bytes→percent conversion (`worker.ex:488`), the `>150%` counter-wrap drop,
//! `at_risk?`/warning-horizon policy, the Ash upsert, telemetry, and the
//! `VerdictEmitter` all stay in the worker. The kernel receives already-resolved
//! `(timestamp, value)` points and emits a fit. For bounded signals the worker passes
//! physical value bounds so the emitted horizon projection/bands remain possible
//! values; the ETA still comes from the raw fit.

mod exhaustion;
mod holt_winters;
mod linear;
mod stats;
mod types;

#[cfg(test)]
mod tests;

use crate::disposition::Disposition;
use deep_causality_core::{CausalFlow, CausalityError, CausalityErrorEnum};

use holt_winters::{is_seasonal, seasonal_forecast};
use linear::linear_forecast;
use types::{CapacityState, CapacityValue, NormPoint};

pub use types::{
    CapacityConfig, CapacityDisposition, CapacityModelKind, CapacityPoint, CapacityRow,
};

/// `@seasonal_strength_threshold` (`model.ex:13`): the seasonal autodetect fires
/// only when the seasonal amplitude is at least this fraction of the total stddev.
const SEASONAL_STRENGTH_THRESHOLD: f64 = 0.25;

/// `@epsilon` (`model.ex:14`): the least-squares denominator guard and the
/// stddev/range floors. PRESERVED EXACTLY — using `f64::EPSILON` here would diverge
/// from `model.ex`.
const EPSILON: f64 = 1.0e-9;

/// Nominal coverage level of the emitted prediction interval (95%). Surfaced in the
/// `confidence` field for ABI stability, but it is the INTERVAL's coverage level —
/// NOT a fit-quality probability. The old heuristic `clamp(1 - rmse/scale)` was an
/// overclaim (a number in `[0,1]` that quantified nothing) and is removed (D2).
pub(super) const COVERAGE_LEVEL: f64 = 0.95;

/// Standard-normal 0.975 quantile — the large-sample critical value for the 95%
/// prediction interval. For the `min_history >= 24` windows the worker feeds, the
/// Student-t quantile for `n-2` df is within a few percent of this; the load-bearing
/// fix is the leverage term that widens the band with the horizon, not the exact
/// critical value (a `t`-quantile is a drop-in refinement).
pub(super) const Z_0975: f64 = 1.959_963_984_540_054;

/// `@exhaustion_horizon_multiplier` (`model.ex:21`): a projected threshold crossing
/// more than this many horizons past the last sample is noise from a near-zero
/// slope (the year-5256 exhaustion source), not a forecast — it collapses to "no
/// projected exhaustion" ([`Disposition::Inactive`]).
const EXHAUSTION_HORIZON_MULTIPLIER: i64 = 10;

/// `@default_horizon_seconds` (`model.ex:10`): 90 days.
pub const DEFAULT_HORIZON_SECONDS: i64 = 90 * 24 * 60 * 60;
/// `@default_min_points` (`model.ex:11`).
pub const DEFAULT_MIN_POINTS: usize = 24;
/// `@default_period` (`model.ex:12`).
pub const DEFAULT_PERIOD: usize = 24;

/// Microseconds per second — the resolution `model.ex` normalizes/diffs at
/// (`DateTime.diff(_, _, :second)` over `:microsecond`-truncated points).
const MICROS_PER_SECOND: i64 = 1_000_000;

/// Clamp the raw projection and its raw prediction-interval bounds to any configured
/// physical value bounds. The interval is computed per model (closed-form OLS for the
/// linear path, residual-bootstrap for Holt-Winters) and passed in as `raw_lower`/
/// `raw_upper`, so the surfaced band is a VALID prediction interval that widens with
/// the horizon — not the old constant `± 1.96·in-sample-RMSE` (D2).
pub(super) fn bounded_projection(
    config: &CapacityConfig,
    raw_projected_value: f64,
    raw_lower: f64,
    raw_upper: f64,
) -> (f64, f64, f64, bool) {
    let projected_value = clamp_to_value_bounds(raw_projected_value, config);
    let lower_bound = clamp_to_value_bounds(raw_lower, config);
    let upper_bound = clamp_to_value_bounds(raw_upper, config);
    let bounded = bounded_changed(raw_projected_value, projected_value)
        || bounded_changed(raw_lower, lower_bound)
        || bounded_changed(raw_upper, upper_bound);

    (projected_value, lower_bound, upper_bound, bounded)
}

fn clamp_to_value_bounds(value: f64, config: &CapacityConfig) -> f64 {
    match normalized_value_bounds(config) {
        Some((min, _max)) if value.is_nan() => min,
        Some((min, _max)) if value == f64::NEG_INFINITY => min,
        Some((_min, max)) if value == f64::INFINITY => max,
        Some((min, max)) if !value.is_finite() => {
            if value.is_sign_negative() {
                min
            } else {
                max
            }
        }
        Some((min, max)) => value.clamp(min, max),
        None => value,
    }
}

fn normalized_value_bounds(config: &CapacityConfig) -> Option<(f64, f64)> {
    match (config.value_min, config.value_max) {
        (Some(min), Some(max)) if min.is_finite() && max.is_finite() && min < max => {
            Some((min, max))
        }
        _ => None,
    }
}

fn bounded_changed(raw: f64, bounded: f64) -> bool {
    if raw.is_finite() && bounded.is_finite() {
        (raw - bounded).abs() > EPSILON
    } else {
        raw.to_bits() != bounded.to_bits()
    }
}

/// Score one capacity row. The public seam the NIF's per-row loop calls. Always
/// returns a [`CapacityDisposition`]; gates resolve to a [`Disposition`] variant,
/// never a panic (graft #1).
pub fn dispose_capacity(row: CapacityRow, config: &CapacityConfig) -> CapacityDisposition {
    let series_key = row.series_key.clone();

    let disposition = match run_capacity_flow(row, config) {
        Ok(disposition) => disposition,
        // The flow itself never returns Err in practice (every gate is a Value), but
        // the monadic `finish()` is fallible — degrade to a Skipped value.
        Err(err) => Disposition::Skipped {
            reason: format!("capacity flow error: {err}"),
        },
    };

    CapacityDisposition {
        series_key,
        disposition,
    }
}

/// Drive the capacity `CausalFlow`: normalize the window into State, run the history
/// gate + model selection + fit, finalize. Mirrors `run_seasonal_flow`
/// (`seasonal.rs:316`) and the `forecast/2` dispatch (`model.ex:42-63`).
fn run_capacity_flow(row: CapacityRow, config: &CapacityConfig) -> Result<Disposition, String> {
    let state = CapacityState {
        row,
        points: Vec::new(),
    };

    let value = CausalFlow::process(state)
        .context(*config)
        .map(|()| CapacityValue::Evaluate)
        .update_value_state_context(hydrate_window)
        .branch_with(
            |value, _state, _context| {
                // The fit arm: the history gate passed, so a model fit must run.
                matches!(value, CapacityValue::Evaluate)
            },
            |fit| fit,
            |gated| gated,
        )
        .update_value_state_context(fit_forecast)
        .finish()
        .map_err(|err| err.to_string())?;

    match value {
        CapacityValue::Disposed(d) => Ok(d),
        CapacityValue::Evaluate => {
            Err(CausalityError::new(CausalityErrorEnum::ValueNotAvailable).to_string())
        }
    }
}

/// Stage 1 of the flow: normalize the window and apply the `insufficient_history`
/// gate (`model.ex:46`). On gate the Value is set to the `Skipped` disposition; on
/// pass the Value stays `Evaluate` so the branch routes to the fit. Mirrors the
/// `length(points) < min_points` check (`model.ex:46`).
fn hydrate_window(
    value: CapacityValue,
    mut state: CapacityState,
    context: Option<CapacityConfig>,
) -> (CapacityValue, CapacityState, Option<CapacityConfig>) {
    let Some(config) = context.as_ref() else {
        return (
            CapacityValue::Disposed(Disposition::Skipped {
                reason: "capacity config missing".to_string(),
            }),
            state,
            context,
        );
    };

    state.points = state.normalize();

    // `is_empty()` is explicit so a `min_history` of 0 (which would make the length
    // gate `len < 0` unsatisfiable) still skips an empty window rather than indexing
    // `points[len - 1]` in the linear/seasonal fit. The worker normalizes
    // `min_history` to a positive default, so this only changes the degenerate case.
    if state.points.is_empty() || state.points.len() < config.min_history {
        // `{:skip, "insufficient_history", ...}` (model.ex:47) → Skipped via the
        // value channel (graft #1), never a panic. The `sample_count`/`min_points`
        // diagnostics travel as the worker already has them.
        return (
            CapacityValue::Disposed(Disposition::Skipped {
                reason: "insufficient_history".to_string(),
            }),
            state,
            context,
        );
    }

    (value, state, context)
}

/// Stage 2 of the flow: select the model and compute the fit. Only runs on the fit
/// arm (history gate passed). Mirrors the `cond` dispatch (`model.ex:52-61`).
fn fit_forecast(
    value: CapacityValue,
    state: CapacityState,
    context: Option<CapacityConfig>,
) -> (CapacityValue, CapacityState, Option<CapacityConfig>) {
    // On the gated arm the Value is already a Skipped disposition; pass it through.
    let CapacityValue::Evaluate = value else {
        return (value, state, context);
    };
    let Some(config) = context.as_ref() else {
        return (
            CapacityValue::Disposed(Disposition::Skipped {
                reason: "capacity config missing".to_string(),
            }),
            state,
            context,
        );
    };

    let disposition = forecast(&state.points, config);
    (CapacityValue::Disposed(disposition), state, context)
}

/// The model dispatch (`forecast/2`, `model.ex:42-63`, history-gate already passed).
fn forecast(points: &[NormPoint], config: &CapacityConfig) -> Disposition {
    match config.model_kind {
        CapacityModelKind::Seasonal => seasonal_forecast(points, config),
        CapacityModelKind::Auto if is_seasonal(points, config.period) => {
            seasonal_forecast(points, config)
        }
        CapacityModelKind::Auto | CapacityModelKind::Linear => linear_forecast(points, config),
    }
}
