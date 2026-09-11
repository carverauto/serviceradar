// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The exhaustion-ETA projections: the linear crossing (`exhaustion_at/6`), the
//! seasonal step search (`seasonal_exhaustion_at/9`), the seasonal projection
//! (`project_seasonal/6`), and the half-away ETA rounding (`model.ex:252-312`).

use super::holt_winters::season_at;
use super::{EXHAUSTION_HORIZON_MULTIPLIER, MICROS_PER_SECOND};

const HISTORY_SPAN_EXTRAPOLATION_MULTIPLIER: i64 = 2;

/// The linear crossing outcome: the capped ETA the worker surfaces, the uncapped
/// crossing it can explain, whether the history cap alone withheld the ETA, and the
/// cap that was applied. All times are **absolute unix microseconds**.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct LinearExhaustion {
    pub(super) eta_unix_micros: Option<i64>,
    pub(super) raw_unix_micros: Option<i64>,
    pub(super) history_capped: bool,
    pub(super) extrapolation_cap_seconds: i64,
}

/// `exhaustion_at/6` (`model.ex:252-275`), extended to report the uncapped
/// crossing. `eta_unix_micros` keeps the legacy semantics exactly
/// (`DateTime.add(first_at, round(cross_x), :second)`, or `None` for non-positive
/// slope, missing threshold, already-crossed, beyond the `10×`-horizon noise cap,
/// or beyond twice the observed span). `raw_unix_micros` is `None` only for the
/// first four of those cases: a crossing beyond twice the observed span is still
/// a crossing, so it is reported with `history_capped = true`.
pub(super) fn exhaustion_at(
    first_at_unix_micros: i64,
    last_x: i64,
    slope: f64,
    intercept: f64,
    threshold: Option<f64>,
    horizon_seconds: i64,
) -> LinearExhaustion {
    let observed_span_cap = last_x
        .saturating_mul(HISTORY_SPAN_EXTRAPOLATION_MULTIPLIER)
        .max(1);
    let legacy_horizon_cap = horizon_seconds.saturating_mul(EXHAUSTION_HORIZON_MULTIPLIER);
    let extrapolation_cap = observed_span_cap.min(legacy_horizon_cap);
    let none = LinearExhaustion {
        eta_unix_micros: None,
        raw_unix_micros: None,
        history_capped: false,
        extrapolation_cap_seconds: extrapolation_cap,
    };

    // `when slope <= 0.0` (model.ex:252).
    if slope <= 0.0 {
        return none;
    }
    // `when not is_number(threshold)` (model.ex:255).
    let Some(threshold) = threshold else {
        return none;
    };

    let cross_x = (threshold - intercept) / slope;
    let last_x_f = last_x as f64;

    // `cross_x <= last_x` → nil (model.ex:265). Already crossed in-window.
    if cross_x <= last_x_f {
        return none;
    }
    // Beyond `10×` the horizon is noise from a near-zero slope (the year-5256
    // source), not a crossing anyone should be shown.
    if cross_x > (last_x + legacy_horizon_cap) as f64 {
        return none;
    }
    // `DateTime.add(first_at, round(cross_x), :second)` (model.ex:273). Elixir
    // `round/1` rounds half away from zero; `f64::round()` matches. The ETA carries
    // the first_at sub-second component (micros) plus the rounded whole seconds.
    let crossing = first_at_unix_micros + round_half_away(cross_x) * MICROS_PER_SECOND;
    let max_cross_x = (last_x + extrapolation_cap) as f64;

    // `cross_x > max_cross_x` → nil (model.ex:269): the trend is too short to
    // support the extrapolation. Report the crossing anyway, flagged.
    if cross_x > max_cross_x {
        return LinearExhaustion {
            eta_unix_micros: None,
            raw_unix_micros: Some(crossing),
            history_capped: true,
            extrapolation_cap_seconds: extrapolation_cap,
        };
    }

    LinearExhaustion {
        eta_unix_micros: Some(crossing),
        raw_unix_micros: Some(crossing),
        history_capped: false,
        extrapolation_cap_seconds: extrapolation_cap,
    }
}

/// `seasonal_exhaustion_at/9` (`model.ex:277-308`): the first projection step whose
/// value reaches the threshold, as absolute unix micros. `None` for missing
/// threshold or no crossing within `steps`.
#[allow(clippy::too_many_arguments)]
pub(super) fn seasonal_exhaustion_at(
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
pub(super) fn project_seasonal(
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

/// Elixir `round/1`: round half **away from zero** (round half up for positives).
/// `f64::round()` has the same half-away-from-zero rule, but we coerce to `i64`
/// explicitly so the ETA arithmetic stays integral.
pub(super) fn round_half_away(x: f64) -> i64 {
    x.round() as i64
}
