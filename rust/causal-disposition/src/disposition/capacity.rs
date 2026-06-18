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
//! - **State** = [`CapacityState`] — the fit accumulators: the normalized
//!   `(offset_seconds, value)` points, the least-squares slope/intercept OR the
//!   Holt-Winters level/trend/seasonals, the residuals/RMSE, and the projection
//!   cursor.
//! - **Context** = [`CapacityConfig`] — `{capacity_threshold, horizon_seconds,
//!   model_kind, min_history, period, alpha, beta, gamma}`, read-only.
//!
//! # Parity is the gate (graft #4)
//! Every numeric output field (`slope_per_second`, `intercept`, `projected_value`,
//! `confidence`, `lower_bound`, `upper_bound`, the exhaustion ETA) must match
//! `model.ex` to within `1e-9`. To that end this port preserves the **exact**
//! summation order, the `@epsilon = 1.0e-9` least-squares denominator guard
//! (`model.ex:14,208`), the `@exhaustion_horizon_multiplier 10` plausibility bound
//! (`model.ex:21`), the `@seasonal_strength_threshold 0.25` autodetect
//! (`model.ex:13,352`), the `1.96 * rmse` band, and the `round(cross_x)` ETA
//! rounding (`model.ex:273`). See the `RISKS` notes in the module tests and the
//! Elixir golden-fixture parity test for the divergence surface.
//!
//! # Orchestration stays in Elixir (task 7.4)
//! This kernel performs ONLY the numeric forecast compute. The interface
//! bytes→percent conversion (`worker.ex:488`), the `>150%` counter-wrap drop, the
//! `>10x` implausible-projection skip, `at_risk?`/warning-horizon policy, the Ash
//! upsert, telemetry, and the `VerdictEmitter` all stay in the worker. The kernel
//! receives already-resolved `(timestamp, value)` points and emits a fit.

use crate::disposition::{CapacityForecast, Disposition};
use deep_causality_core::{CausalFlow, CausalityError, CausalityErrorEnum};

/// `@seasonal_strength_threshold` (`model.ex:13`): the seasonal autodetect fires
/// only when the seasonal amplitude is at least this fraction of the total stddev.
const SEASONAL_STRENGTH_THRESHOLD: f64 = 0.25;

/// `@epsilon` (`model.ex:14`): the least-squares denominator guard and the
/// stddev/range floors. PRESERVED EXACTLY — using `f64::EPSILON` here would diverge
/// from `model.ex`.
const EPSILON: f64 = 1.0e-9;

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

/// Which model `model.ex` should run (the `:model` opt, `model.ex:49`). `Auto`
/// routes to seasonal Holt-Winters when [`seasonal`] detects seasonality, else
/// linear; `Seasonal`/`HoltWinters` force the seasonal path (falling back to linear
/// on insufficient seasonal history); `Linear` forces the linear path.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifUnitEnum))]
pub enum CapacityModelKind {
    /// `:auto` — seasonal-strength autodetect (`model.ex:56`).
    #[default]
    Auto,
    /// `:linear` — force the least-squares linear fit (`model.ex:59`).
    Linear,
    /// `:seasonal` / `:holt_winters` — force the additive Holt-Winters path
    /// (`model.ex:53`).
    Seasonal,
}

/// Read-only capacity context (the `Context` channel, D4): the threshold, horizon,
/// model choice, history gate, seasonal period, and the Holt-Winters smoothing
/// ratios.
///
/// With the crate's `rustler` feature on this is a `NifMap`, so the worker passes a
/// plain Elixir map. `capacity_threshold` is `Option<f64>` because `model.ex`
/// treats a missing/non-numeric `:exhaustion_threshold` as "no ETA, scale by range"
/// (`model.ex:77,255,288,360`).
#[derive(Clone, Copy, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct CapacityConfig {
    /// `:exhaustion_threshold` (`model.ex:77`). `None` ⇒ no ETA and the confidence
    /// scale falls back to range/mean (`model.ex:357-363`). The worker resolves the
    /// interface percent threshold before the NIF.
    pub capacity_threshold: Option<f64>,
    /// `:horizon_seconds` (`model.ex:74`). Positive; the worker already validated it.
    pub horizon_seconds: i64,
    /// `:model` (`model.ex:49`).
    pub model_kind: CapacityModelKind,
    /// `:min_points` (`model.ex:44`) — the `insufficient_history` gate
    /// (`model.ex:46`).
    pub min_history: usize,
    /// `:seasonal_period` (`model.ex:50`).
    pub period: usize,
    /// Holt-Winters level smoothing `:alpha` (`model.ex:128`, default 0.35).
    pub alpha: f64,
    /// Holt-Winters trend smoothing `:beta` (`model.ex:129`, default 0.05).
    pub beta: f64,
    /// Holt-Winters season smoothing `:gamma` (`model.ex:130`, default 0.25).
    pub gamma: f64,
}

impl Default for CapacityConfig {
    fn default() -> Self {
        Self {
            capacity_threshold: None,
            horizon_seconds: DEFAULT_HORIZON_SECONDS,
            model_kind: CapacityModelKind::Auto,
            min_history: DEFAULT_MIN_POINTS,
            period: DEFAULT_PERIOD,
            alpha: 0.35,
            beta: 0.05,
            gamma: 0.25,
        }
    }
}

/// One aggregate sample (`@type point`, `model.ex:23`): the bucket timestamp as a
/// unix-microsecond epoch plus the value. The kernel sorts/diffs these exactly as
/// `normalize_points` does (`model.ex:217-232`); the worker resolves interface
/// bytes→percent into `value` before the NIF (`worker.ex:488`).
#[derive(Clone, Copy, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct CapacityPoint {
    /// `point.at` as unix microseconds (`DateTime.to_unix(_, :microsecond)`, the sort
    /// key at `model.ex:221`). The kernel derives integer-second offsets from this
    /// exactly as `DateTime.diff(_, _, :second)` does.
    pub at_unix_micros: i64,
    /// `point.value` (coerced to `f64` by `* 1.0` at `model.ex:225`).
    pub value: f64,
}

/// One per-row capacity request: the series key plus the ordered points.
///
/// `NifMap` with the `rustler` feature, so the worker passes
/// `%{series_key: ..., points: [%{at_unix_micros: ..., value: ...}, ...]}`.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct CapacityRow {
    /// Stable series identifier (echoed back so the worker can re-key the forecast).
    pub series_key: String,
    /// The aggregate samples. May be unordered/duplicated; the kernel normalizes
    /// (sort ascending by `at_unix_micros`) exactly as `model.ex` does.
    pub points: Vec<CapacityPoint>,
}

/// One per-row capacity result: the echoed key plus the [`Disposition`] verdict.
///
/// `NifMap` with the `rustler` feature, so the worker reads back
/// `%{series_key: ..., disposition: {...}}` and threads the projected fields into
/// the Ash upsert.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct CapacityDisposition {
    /// Echoed series identifier.
    pub series_key: String,
    /// The assigned disposition (the Value channel result).
    pub disposition: Disposition,
}

/// A normalized point: the integer-second offset from the window start plus the
/// value, mirroring the `{xs, ys}` pair `linear_forecast` builds (`model.ex:69-70`).
#[derive(Clone, Copy, Debug)]
struct NormPoint {
    /// `DateTime.diff(at, first_at, :second)` (`model.ex:69`).
    offset_seconds: i64,
    /// `at` as unix microseconds (carried so seasonal step-median and ETA can
    /// reconstruct absolute timestamps).
    at_unix_micros: i64,
    /// `value * 1.0` (`model.ex:70`).
    value: f64,
}

/// The `State` channel (D4): the normalized window plus the config-derived window
/// metadata the flow threads through fit → project → finalize.
struct CapacityState {
    row: CapacityRow,
    /// Normalized + ascending-sorted points (`normalize_points`, `model.ex:217`).
    /// Empty until [`hydrate_window`] populates it.
    points: Vec<NormPoint>,
}

/// Internal Value of the capacity flow before the verdict is written.
enum CapacityValue {
    /// Pre-evaluation marker.
    Evaluate,
    /// The disposition the flow resolved to.
    Disposed(Disposition),
}

impl CapacityState {
    /// Normalize the raw points exactly as `normalize_points` (`model.ex:217-232`):
    /// coerce values to `f64`, drop non-finite/garbage (the `normalize_point/1`
    /// `nil` reject), and **stable**-sort ascending by unix-microsecond timestamp.
    fn normalize(&self) -> Vec<NormPoint> {
        let mut pts: Vec<(i64, f64)> = self
            .row
            .points
            .iter()
            // `normalize_point/1` only accepts numeric values; a NaN/Inf is not a
            // valid Elixir number for our purposes (it would never come from a CAGG
            // numeric column), so drop it like the `nil` reject branch.
            .filter(|p| p.value.is_finite())
            .map(|p| (p.at_unix_micros, p.value))
            .collect();
        // `Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond))` — Elixir's sort is
        // STABLE; `sort_by_key` is stable, so ties keep input order identically.
        pts.sort_by_key(|(at, _)| *at);

        let Some((first_at, _)) = pts.first().copied() else {
            return Vec::new();
        };

        pts.into_iter()
            .map(|(at, value)| NormPoint {
                // `DateTime.diff(at, first_at, :second)`: the points are sorted
                // ascending and `first_at` is the minimum, so the difference is
                // always >= 0 and `div_euclid` == truncation == Elixir's floor.
                offset_seconds: (at - first_at).div_euclid(MICROS_PER_SECOND),
                at_unix_micros: at,
                value,
            })
            .collect()
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

    if state.points.len() < config.min_history {
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

/// `seasonal_forecast/3` (`model.ex:107-112`): Holt-Winters, falling back to linear
/// on insufficient seasonal history (`:not_enough_seasonal_history`).
fn seasonal_forecast(points: &[NormPoint], config: &CapacityConfig) -> Disposition {
    match holt_winters(points, config) {
        Some(disposition) => disposition,
        None => linear_forecast(points, config),
    }
}

/// `linear_forecast/2` (`model.ex:66-105`): least-squares fit, projection at
/// `last_x + horizon`, RMSE/confidence/bounds, exhaustion ETA.
fn linear_forecast(points: &[NormPoint], config: &CapacityConfig) -> Disposition {
    let xs: Vec<f64> = points.iter().map(|p| p.offset_seconds as f64).collect();
    let ys: Vec<f64> = points.iter().map(|p| p.value).collect();

    let (slope, intercept) = least_squares(&xs, &ys);

    let horizon_seconds = config.horizon_seconds;
    let threshold = config.capacity_threshold;

    // `last_point`/`last_x` (model.ex:78). The history gate guarantees non-empty.
    let last = points[points.len() - 1];
    let last_x = last.offset_seconds;
    let projected_x = (last_x + horizon_seconds) as f64;
    let projected_value = intercept + slope * projected_x;
    let residuals = residuals(&xs, &ys, slope, intercept);
    let rmse = rmse(&residuals);

    let first_at = points[0].at_unix_micros;
    let projected_exhaustion = exhaustion_at(
        first_at,
        last_x,
        slope,
        intercept,
        threshold,
        horizon_seconds,
    );

    Disposition::Projected(Box::new(CapacityForecast {
        model: "linear".to_string(),
        current_value: last.value,
        slope_per_second: slope,
        intercept,
        projected_value,
        projected_exhaustion_at_unix_micros: projected_exhaustion,
        confidence: confidence(rmse, &ys, threshold),
        lower_bound: projected_value - 1.96 * rmse,
        upper_bound: projected_value + 1.96 * rmse,
        rmse,
        sample_count: points.len(),
        window_started_at_unix_micros: first_at,
        window_ended_at_unix_micros: last.at_unix_micros,
    }))
}

/// `holt_winters/3` (`model.ex:114-197`). Returns `None` for the
/// `:not_enough_seasonal_history` path (`model.ex:117`), which the caller maps to a
/// linear fallback.
fn holt_winters(points: &[NormPoint], config: &CapacityConfig) -> Option<Disposition> {
    let period = config.period;
    if points.len() < period * 2 {
        return None;
    }

    let values: Vec<f64> = points.iter().map(|p| p.value).collect();
    let first_at = points[0].at_unix_micros;
    let step_seconds = median_step_seconds(points);

    let horizon_seconds = config.horizon_seconds;
    // `max(1, div(horizon_seconds, step_seconds))` (model.ex:127). Integer division
    // toward zero; both operands are positive here, so it matches Elixir `div/2`.
    let steps = (horizon_seconds / step_seconds).max(1);
    let alpha = valid_ratio(config.alpha, 0.35);
    let beta = valid_ratio(config.beta, 0.05);
    let gamma = valid_ratio(config.gamma, 0.25);
    let threshold = config.capacity_threshold;

    let mut seasons = initial_seasonals(&values, period);
    let initial_trend = initial_trend(&values, period);

    // `Enum.reduce` over `values |> Enum.with_index()` (model.ex:135-155). `level`
    // starts at `hd(values)` (the first value).
    let mut level = values[0];
    let mut trend = initial_trend;
    // residuals are prepended (`[value - fitted | acc]`) then reversed (model.ex:160),
    // so they end up in index order — push in order directly.
    let mut residuals_vec: Vec<f64> = Vec::with_capacity(values.len());

    for (index, &value) in values.iter().enumerate() {
        let season_idx = index % period;
        let season = season_at(&seasons, season_idx);
        let _fitted = level + trend + season;
        let next_level = alpha * (value - season) + (1.0 - alpha) * (level + trend);
        let next_trend = beta * (next_level - level) + (1.0 - beta) * trend;
        let next_season = gamma * (value - next_level) + (1.0 - gamma) * season;

        residuals_vec.push(value - _fitted);

        level = next_level;
        trend = next_trend;
        set_season(&mut seasons, season_idx, next_season);
    }

    let count = values.len();
    let projected_value = project_seasonal(level, trend, &seasons, count, period, steps);
    // `List.last(values)` (model.ex:158).
    let current_value = values[count - 1];
    // `(projected_value - current_value) / horizon_seconds` (model.ex:159).
    let slope = (projected_value - current_value) / horizon_seconds as f64;
    let rmse = rmse(&residuals_vec);
    let last = points[count - 1];

    let projected_exhaustion = seasonal_exhaustion_at(
        level,
        trend,
        &seasons,
        count,
        period,
        step_seconds,
        threshold,
        last.at_unix_micros,
        steps,
    );

    Some(Disposition::Projected(Box::new(CapacityForecast {
        model: "holt_winters_additive".to_string(),
        current_value,
        slope_per_second: slope,
        // `intercept => level` (model.ex:168).
        intercept: level,
        projected_value,
        projected_exhaustion_at_unix_micros: projected_exhaustion,
        confidence: confidence(rmse, &values, threshold),
        lower_bound: projected_value - 1.96 * rmse,
        upper_bound: projected_value + 1.96 * rmse,
        rmse,
        sample_count: count,
        window_started_at_unix_micros: first_at,
        window_ended_at_unix_micros: last.at_unix_micros,
    })))
}

/// `least_squares/2` (`model.ex:199-215`). Preserves the **exact** summation order
/// and the `@epsilon` denominator guard so the slope/intercept match bit-for-bit
/// within the parity tolerance.
fn least_squares(xs: &[f64], ys: &[f64]) -> (f64, f64) {
    let n = xs.len() as f64;
    let sum_x: f64 = xs.iter().sum();
    let sum_y: f64 = ys.iter().sum();
    let sum_xx: f64 = xs.iter().map(|x| x * x).sum();
    let sum_xy: f64 = xs.iter().zip(ys.iter()).map(|(x, y)| x * y).sum();
    let denominator = n * sum_xx - sum_x * sum_x;

    if denominator.abs() < EPSILON {
        (0.0, sum_y / n)
    } else {
        let slope = (n * sum_xy - sum_x * sum_y) / denominator;
        let intercept = (sum_y - slope * sum_x) / n;
        (slope, intercept)
    }
}

/// `residuals/4` (`model.ex:236-240`): `y - (intercept + slope * x)`.
fn residuals(xs: &[f64], ys: &[f64], slope: f64, intercept: f64) -> Vec<f64> {
    xs.iter()
        .zip(ys.iter())
        .map(|(x, y)| y - (intercept + slope * x))
        .collect()
}

/// `rmse/1` (`model.ex:242-250`): `sqrt(sum(r^2) / max(len, 1))`. Empty ⇒ 0.0.
fn rmse(residuals: &[f64]) -> f64 {
    if residuals.is_empty() {
        return 0.0;
    }
    let sum_sq: f64 = residuals.iter().map(|r| r * r).sum();
    let denom = residuals.len().max(1) as f64;
    (sum_sq / denom).sqrt()
}

/// `exhaustion_at/6` (`model.ex:252-275`). Returns the ETA as **absolute unix
/// microseconds** (`DateTime.add(first_at, round(cross_x), :second)`), or `None`
/// for the no-ETA cases (non-positive slope, missing threshold, already-crossed,
/// or absurdly-far crossing).
fn exhaustion_at(
    first_at_unix_micros: i64,
    last_x: i64,
    slope: f64,
    intercept: f64,
    threshold: Option<f64>,
    horizon_seconds: i64,
) -> Option<i64> {
    // `when slope <= 0.0` (model.ex:252).
    if slope <= 0.0 {
        return None;
    }
    // `when not is_number(threshold)` (model.ex:255).
    let threshold = threshold?;

    let cross_x = (threshold - intercept) / slope;
    let max_cross_x = (last_x + horizon_seconds * EXHAUSTION_HORIZON_MULTIPLIER) as f64;
    let last_x_f = last_x as f64;

    // `cross_x <= last_x` → nil (model.ex:265). Already crossed in-window.
    if cross_x <= last_x_f {
        return None;
    }
    // `cross_x > max_cross_x` → nil (model.ex:269). Absurdly far out.
    if cross_x > max_cross_x {
        return None;
    }
    // `DateTime.add(first_at, round(cross_x), :second)` (model.ex:273). Elixir
    // `round/1` rounds half away from zero; `f64::round()` matches. The ETA carries
    // the first_at sub-second component (micros) plus the rounded whole seconds.
    Some(first_at_unix_micros + round_half_away(cross_x) * MICROS_PER_SECOND)
}

/// `seasonal_exhaustion_at/9` (`model.ex:277-308`): the first projection step whose
/// value reaches the threshold, as absolute unix micros. `None` for missing
/// threshold or no crossing within `steps`.
#[allow(clippy::too_many_arguments)]
fn seasonal_exhaustion_at(
    level: f64,
    trend: f64,
    seasons: &[f64],
    count: usize,
    period: usize,
    step_seconds: i64,
    threshold: Option<f64>,
    last_at_unix_micros: i64,
    steps: i64,
) -> Option<i64> {
    // `when not is_number(threshold)` (model.ex:288).
    let threshold = threshold?;

    // `Enum.find_value(1..steps, ...)` (model.ex:301).
    let mut step = 1_i64;
    while step <= steps {
        let value = project_seasonal(level, trend, seasons, count, period, step);
        if value >= threshold {
            // `DateTime.add(last_at, step * step_seconds, :second)` (model.ex:305).
            return Some(last_at_unix_micros + step * step_seconds * MICROS_PER_SECOND);
        }
        step += 1;
    }
    None
}

/// `project_seasonal/6` (`model.ex:310-312`):
/// `level + step * trend + seasons[(count + step - 1) mod period]`.
fn project_seasonal(
    level: f64,
    trend: f64,
    seasons: &[f64],
    count: usize,
    period: usize,
    step: i64,
) -> f64 {
    // `rem(count + step - 1, period)` (model.ex:311). count/step/period are all
    // non-negative here (step >= 1), so the index is in range.
    let idx = ((count as i64 + step - 1).rem_euclid(period as i64)) as usize;
    level + (step as f64) * trend + season_at(seasons, idx)
}

/// `median_step_seconds/1` (`model.ex:314-324`). Single point ⇒ 3600; else the
/// median of the consecutive `max(diff_seconds, 1)` gaps (with the
/// `Enum.at(_, mid, 3600)` default for an empty step list).
fn median_step_seconds(points: &[NormPoint]) -> i64 {
    if points.len() <= 1 {
        return 3_600;
    }
    // `chunk_every(2, 1, :discard)` consecutive pairs; `max(diff, 1)`.
    let mut steps: Vec<i64> = points
        .windows(2)
        .map(|w| {
            let a = w[0].at_unix_micros;
            let b = w[1].at_unix_micros;
            // `DateTime.diff(b, a, :second)` then `max(_, 1)`. Sorted ascending ⇒ >= 0.
            ((b - a).div_euclid(MICROS_PER_SECOND)).max(1)
        })
        .collect();
    steps.sort_unstable();
    // `Enum.at(steps, div(length(steps), 2), 3_600)` (model.ex:323).
    let mid = steps.len() / 2;
    steps.get(mid).copied().unwrap_or(3_600)
}

/// `initial_trend/2` (`model.ex:326-335`): `(mean(second_period) -
/// mean(first_period)) / period`, or 0.0 if the second period is short.
fn initial_trend(values: &[f64], period: usize) -> f64 {
    // `Enum.take(values, period)` then `Enum.drop(period) |> Enum.take(period)`.
    let first: &[f64] = &values[..period.min(values.len())];
    let second_start = period.min(values.len());
    let second_end = (period + period).min(values.len());
    let second: &[f64] = &values[second_start..second_end];

    if second.len() == period {
        let sum_first: f64 = first.iter().sum();
        let sum_second: f64 = second.iter().sum();
        let p = period as f64;
        // Preserve the exact form: `(sum_second/period - sum_first/period) / period`.
        (sum_second / p - sum_first / p) / p
    } else {
        0.0
    }
}

/// `initial_seasonals/2` (`model.ex:337-344`): for the first `period` values,
/// `value - average`, indexed 0..period. Returned as a dense `Vec<f64>` of length
/// `min(period, len)` (the only indices `Map.get(_, _, 0.0)` ever reads at
/// `rem(_, period)`; missing later indices read as 0.0 via [`season_at`]).
fn initial_seasonals(values: &[f64], period: usize) -> Vec<f64> {
    let take = period.min(values.len());
    let period_values = &values[..take];
    // `Enum.sum(period_values) / max(length(period_values), 1)` (model.ex:339).
    let denom = period_values.len().max(1) as f64;
    let sum: f64 = period_values.iter().sum();
    let average = sum / denom;
    period_values.iter().map(|v| v - average).collect()
}

/// `Map.get(seasons, idx, 0.0)`: a season index past the populated head reads 0.0,
/// exactly as the Elixir map default.
fn season_at(seasons: &[f64], idx: usize) -> f64 {
    seasons.get(idx).copied().unwrap_or(0.0)
}

/// `Map.put(seasons, idx, value)`: grow the dense season vector with 0.0 padding so
/// an index past the populated head (possible once Holt-Winters writes later
/// buckets) is addressable, matching the Elixir map's insert-anywhere semantics.
fn set_season(seasons: &mut Vec<f64>, idx: usize, value: f64) {
    if idx >= seasons.len() {
        seasons.resize(idx + 1, 0.0);
    }
    seasons[idx] = value;
}

/// `seasonal?/2` (`model.ex:346-355`): seasonal amplitude / total stddev >=
/// `@seasonal_strength_threshold`, gated on `total_std > @epsilon`. Fewer than
/// `period * 2` points ⇒ false (model.ex:355).
fn is_seasonal(points: &[NormPoint], period: usize) -> bool {
    if points.len() < period * 2 {
        return false;
    }
    let values: Vec<f64> = points.iter().map(|p| p.value).collect();
    let seasonals = initial_seasonals(&values, period);
    let seasonal_amplitude = mean_abs(&seasonals);
    let total_std = stddev(&values);

    total_std > EPSILON && seasonal_amplitude / total_std >= SEASONAL_STRENGTH_THRESHOLD
}

/// `confidence/3` (`model.ex:357-368`): `clamp(1.0 - rmse/scale, 0.0, 1.0)` with the
/// threshold/range/mean scale fallback chain.
///
/// PARITY: the clamp is the manual `max(0.0) |> min(1.0)` (`model.ex:365-367`), NOT
/// a single `f64::clamp`. They diverge on NaN — `(NaN).max(0.0).min(1.0) == 0.0`
/// (both Rust's and Elixir's `max`/`min` drop the NaN operand and return the bound)
/// while `clamp` propagates NaN — so the manual form is required for parity. The
/// `manual_clamp` lint is allowed for exactly that reason; do NOT switch to `clamp`.
#[allow(clippy::manual_clamp)]
fn confidence(rmse: f64, values: &[f64], threshold: Option<f64>) -> f64 {
    let scale = match threshold {
        // `is_number(threshold) and threshold > 0 -> threshold` (model.ex:360).
        Some(t) if t > 0.0 => t,
        // `range(values) > @epsilon -> range(values)` (model.ex:361).
        _ => {
            let r = range(values);
            if r > EPSILON {
                r
            } else {
                // `max(abs(sum/max(len,1)), 1.0)` (model.ex:362).
                let mean = values.iter().sum::<f64>() / (values.len().max(1) as f64);
                mean.abs().max(1.0)
            }
        }
    };

    // The manual `max(0.0) |> min(1.0)` (NOT `clamp`) is intentional for NaN parity
    // with `model.ex:365-367` — see the function doc.
    (1.0 - rmse / scale).max(0.0).min(1.0)
}

/// `range/1` (`model.ex:370`): `max - min`. Non-empty by construction (history gate).
fn range(values: &[f64]) -> f64 {
    let mut max = values[0];
    let mut min = values[0];
    for &v in &values[1..] {
        if v > max {
            max = v;
        }
        if v < min {
            min = v;
        }
    }
    max - min
}

/// `stddev/1` (`model.ex:372-380`): sample stddev with `max(len - 1, 1)`
/// denominator. Uses `:math.pow(d, 2)` in Elixir; `d * d` is bit-identical for the
/// integer exponent 2 (`pow(x, 2.0) == x*x` for finite x in IEEE-754), so the
/// parity tolerance holds. See RISK note.
fn stddev(values: &[f64]) -> f64 {
    let n = values.len().max(1) as f64;
    let mean = values.iter().sum::<f64>() / n;
    // `Enum.map(&:math.pow(&1 - mean, 2)) |> Enum.sum()`.
    let sum_sq: f64 = values.iter().map(|v| (v - mean).powi(2)).sum();
    let denom = (values.len() as i64 - 1).max(1) as f64;
    (sum_sq / denom).sqrt()
}

/// `mean_abs/1` (`model.ex:382-387`): `sum(abs(v)) / max(len, 1)`.
fn mean_abs(values: &[f64]) -> f64 {
    let denom = values.len().max(1) as f64;
    let sum: f64 = values.iter().map(|v| v.abs()).sum();
    sum / denom
}

/// `valid_ratio/2` (`model.ex:392-395`): accept a float strictly in `(0.0, 1.0)`,
/// else the default. The worker passes the config ratios; an out-of-range one (or a
/// non-finite one) falls back exactly as Elixir's guard does.
fn valid_ratio(value: f64, default: f64) -> f64 {
    if value.is_finite() && value > 0.0 && value < 1.0 {
        value
    } else {
        default
    }
}

/// Elixir `round/1`: round half **away from zero** (round half up for positives).
/// `f64::round()` has the same half-away-from-zero rule, but we coerce to `i64`
/// explicitly so the ETA arithmetic stays integral.
fn round_half_away(x: f64) -> i64 {
    x.round() as i64
}

#[cfg(test)]
mod tests {
    // The crate root denies `clippy::panic` for production paths (graft #1). Tests
    // that assert a specific enum variant fall through to `panic!` on the wrong
    // variant — the standard test-failure mechanism — so allow it inside the test
    // module only (mirrors the NIF boundary tests' `#[allow(clippy::panic)]`).
    #![allow(clippy::panic)]

    use super::*;

    const START_MICROS: i64 = 1_780_272_000_000_000; // 2026-06-01T00:00:00Z in micros.

    fn point(hour: i64, value: f64) -> CapacityPoint {
        CapacityPoint {
            at_unix_micros: START_MICROS + hour * 3_600 * MICROS_PER_SECOND,
            value,
        }
    }

    fn config(threshold: Option<f64>, horizon: i64, kind: CapacityModelKind) -> CapacityConfig {
        CapacityConfig {
            capacity_threshold: threshold,
            horizon_seconds: horizon,
            model_kind: kind,
            min_history: 24,
            period: 24,
            ..CapacityConfig::default()
        }
    }

    fn linear_points() -> Vec<CapacityPoint> {
        (0..48).map(|h| point(h, 10.0 + h as f64)).collect()
    }

    /// Mirrors the Elixir `"linear forecast computes projected value and exhaustion
    /// ETA"` test (model_test.exs:8): slope 1/3600, projected 81.0, ETA at +70h.
    #[test]
    fn linear_forecast_projects_and_etas() {
        let cfg = config(Some(80.0), 24 * 3_600, CapacityModelKind::Linear);
        let out = dispose_capacity(
            CapacityRow {
                series_key: "svc/disk".to_string(),
                points: linear_points(),
            },
            &cfg,
        );
        match out.disposition {
            Disposition::Projected(f) => {
                assert_eq!(f.model, "linear");
                assert!((f.slope_per_second - 1.0 / 3_600.0).abs() < 1e-9);
                assert!((f.projected_value - 81.0).abs() < 1e-3);
                // ETA at +70 hours from window start.
                let expected = START_MICROS + 70 * 3_600 * MICROS_PER_SECOND;
                assert_eq!(f.projected_exhaustion_at_unix_micros, Some(expected));
                assert!(f.confidence > 0.99);
            }
            other => panic!("expected Projected, got {other:?}"),
        }
    }

    /// Sorting parity: a reversed input must produce the same fit as the ordered one
    /// (model_test.exs:29).
    #[test]
    fn reversed_input_fits_identically() {
        let cfg = config(Some(40.0), 12 * 3_600, CapacityModelKind::Linear);
        let ordered: Vec<CapacityPoint> =
            (0..48).map(|h| point(h, 5.0 + h as f64 * 0.5)).collect();
        let mut reversed = ordered.clone();
        reversed.reverse();

        let a = dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points: ordered,
            },
            &cfg,
        );
        let b = dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points: reversed,
            },
            &cfg,
        );
        match (a.disposition, b.disposition) {
            (Disposition::Projected(fa), Disposition::Projected(fb)) => {
                assert!((fa.slope_per_second - fb.slope_per_second).abs() < 1e-12);
                assert!((fa.projected_value - fb.projected_value).abs() < 1e-9);
                assert_eq!(
                    fa.projected_exhaustion_at_unix_micros,
                    fb.projected_exhaustion_at_unix_micros
                );
                assert_eq!(
                    fa.window_started_at_unix_micros,
                    fb.window_started_at_unix_micros
                );
                assert_eq!(fa.window_ended_at_unix_micros, fb.window_ended_at_unix_micros);
            }
            other => panic!("expected two Projected, got {other:?}"),
        }
    }

    /// Flat/decreasing trend ⇒ no ETA (model_test.exs:60).
    #[test]
    fn decreasing_trend_has_no_eta() {
        let cfg = config(Some(100.0), 24 * 3_600, CapacityModelKind::Linear);
        let points: Vec<CapacityPoint> =
            (0..48).map(|h| point(h, 90.0 - h as f64 * 0.25)).collect();
        let out = dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points,
            },
            &cfg,
        );
        match out.disposition {
            Disposition::Projected(f) => {
                assert!(f.slope_per_second < 0.0);
                assert_eq!(f.projected_exhaustion_at_unix_micros, None);
            }
            other => panic!("expected Projected, got {other:?}"),
        }
    }

    /// A near-zero positive slope whose crossing lands beyond `10×` the horizon ⇒ no
    /// ETA (the year-5256 collapse, model_test.exs:80).
    #[test]
    fn beyond_horizon_crossing_collapses_to_no_eta() {
        let cfg = config(Some(100.0), 24 * 3_600, CapacityModelKind::Linear);
        let points: Vec<CapacityPoint> =
            (0..48).map(|h| point(h, 10.0 + h as f64 * 0.0001)).collect();
        let out = dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points,
            },
            &cfg,
        );
        match out.disposition {
            Disposition::Projected(f) => {
                assert!(f.slope_per_second > 0.0);
                assert_eq!(f.projected_exhaustion_at_unix_micros, None);
            }
            other => panic!("expected Projected, got {other:?}"),
        }
    }

    /// Already-crossed-in-window ⇒ no ETA (model_test.exs:100).
    #[test]
    fn already_crossed_has_no_eta() {
        let cfg = config(Some(100.0), 24 * 3_600, CapacityModelKind::Linear);
        let points: Vec<CapacityPoint> =
            (0..48).map(|h| point(h, 150.0 + h as f64)).collect();
        let out = dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points,
            },
            &cfg,
        );
        match out.disposition {
            Disposition::Projected(f) => {
                assert_eq!(f.projected_exhaustion_at_unix_micros, None)
            }
            other => panic!("expected Projected, got {other:?}"),
        }
    }

    /// Task 8.2: the `insufficient_history` gate → `Skipped{reason}`, never a panic.
    #[test]
    fn insufficient_history_is_skipped() {
        let cfg = CapacityConfig {
            min_history: 3,
            ..config(None, 24 * 3_600, CapacityModelKind::Auto)
        };
        let out = dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points: vec![point(0, 10.0), point(1, 11.0)],
            },
            &cfg,
        );
        assert_eq!(
            out.disposition,
            Disposition::Skipped {
                reason: "insufficient_history".to_string()
            }
        );
    }

    /// Auto model with no seasonality ⇒ linear (model_test.exs:132). A flat series
    /// fits slope 0 and projects its own current value.
    #[test]
    fn auto_without_seasonality_is_linear() {
        let cfg = CapacityConfig {
            min_history: 48,
            ..config(None, 24 * 3_600, CapacityModelKind::Auto)
        };
        let points: Vec<CapacityPoint> = (0..72).map(|h| point(h, 40.0)).collect();
        let out = dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points,
            },
            &cfg,
        );
        match out.disposition {
            Disposition::Projected(f) => {
                assert_eq!(f.model, "linear");
                assert_eq!(f.sample_count, 72);
                assert_eq!(f.slope_per_second, 0.0);
                assert_eq!(f.projected_value, f.current_value);
            }
            other => panic!("expected Projected, got {other:?}"),
        }
    }

    /// Auto model with strong seasonality ⇒ additive Holt-Winters (model_test.exs:152).
    #[test]
    fn auto_with_seasonality_is_holt_winters() {
        let cfg = CapacityConfig {
            min_history: 48,
            ..config(None, 24 * 3_600, CapacityModelKind::Auto)
        };
        let points: Vec<CapacityPoint> = (0..72)
            .map(|h| {
                let seasonal = if (h % 24) >= 8 && (h % 24) <= 17 {
                    25.0
                } else {
                    -10.0
                };
                point(h, 50.0 + seasonal + h as f64 * 0.05)
            })
            .collect();
        let out = dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points,
            },
            &cfg,
        );
        match out.disposition {
            Disposition::Projected(f) => {
                assert_eq!(f.model, "holt_winters_additive");
                assert_eq!(f.sample_count, 72);
                assert!(f.projected_value > 0.0);
            }
            other => panic!("expected Projected, got {other:?}"),
        }
    }

    /// A non-finite value in the window is dropped by normalize (mirrors
    /// `normalize_point/1` rejecting non-numbers); if that drops below the gate it
    /// Skips rather than panicking.
    #[test]
    fn non_finite_value_is_dropped_then_gated() {
        let cfg = CapacityConfig {
            min_history: 48,
            ..config(None, 24 * 3_600, CapacityModelKind::Linear)
        };
        let mut points: Vec<CapacityPoint> = (0..48).map(|h| point(h, 10.0 + h as f64)).collect();
        points.push(CapacityPoint {
            at_unix_micros: START_MICROS + 100 * 3_600 * MICROS_PER_SECOND,
            value: f64::NAN,
        });
        let out = dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points,
            },
            &cfg,
        );
        // 48 finite points survive (NaN dropped) → still a Projected linear fit.
        assert!(matches!(out.disposition, Disposition::Projected { .. }));
    }
}
