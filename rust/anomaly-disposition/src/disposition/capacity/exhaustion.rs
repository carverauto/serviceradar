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

/// `exhaustion_at/6` (`model.ex:252-275`). Returns the ETA as **absolute unix
/// microseconds** (`DateTime.add(first_at, round(cross_x), :second)`), or `None`
/// for the no-ETA cases (non-positive slope, missing threshold, already-crossed,
/// or absurdly-far crossing).
pub(super) fn exhaustion_at(
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
    let observed_span_cap = last_x
        .saturating_mul(HISTORY_SPAN_EXTRAPOLATION_MULTIPLIER)
        .max(1);
    let legacy_horizon_cap = horizon_seconds.saturating_mul(EXHAUSTION_HORIZON_MULTIPLIER);
    let extrapolation_cap = observed_span_cap.min(legacy_horizon_cap);
    let max_cross_x = (last_x + extrapolation_cap) as f64;
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
