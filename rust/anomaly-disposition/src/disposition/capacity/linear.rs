// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The least-squares linear forecast (`linear_forecast/2`) and its supporting
//! least-squares / residual / RMSE helpers (`model.ex:66-105,199-250`).

use super::exhaustion::exhaustion_at;
use super::types::NormPoint;
use super::{COVERAGE_LEVEL, CapacityConfig, EPSILON, Z_0975, bounded_projection};
use crate::disposition::{CapacityForecast, Disposition};

/// `linear_forecast/2` (`model.ex:66-105`): least-squares fit, projection at
/// `last_x + horizon`, RMSE/confidence/bounds, exhaustion ETA.
pub(super) fn linear_forecast(points: &[NormPoint], config: &CapacityConfig) -> Disposition {
    let xs: Vec<f64> = points.iter().map(|p| p.offset_seconds as f64).collect();
    let ys: Vec<f64> = points.iter().map(|p| p.value).collect();

    let (slope, intercept) = least_squares(&xs, &ys);

    let horizon_seconds = config.horizon_seconds;
    let threshold = config.capacity_threshold;

    // `last_point`/`last_x` (model.ex:78). The history gate guarantees non-empty.
    let last = points[points.len() - 1];
    let last_x = last.offset_seconds;
    let projected_x = (last_x + horizon_seconds) as f64;
    let raw_projected_value = intercept + slope * projected_x;
    let residuals = residuals(&xs, &ys, slope, intercept);
    let rmse = rmse(&residuals);
    // Closed-form OLS 95% prediction interval (widens with the horizon) — replaces
    // the old constant ±1.96·RMSE band (D2).
    let (raw_lower, raw_upper) =
        ols_prediction_bounds(&xs, &residuals, projected_x, raw_projected_value);
    let (projected_value, lower_bound, upper_bound, projection_bounded) =
        bounded_projection(config, raw_projected_value, raw_lower, raw_upper);

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
        raw_projected_value,
        projection_bounded,
        projected_exhaustion_at_unix_micros: projected_exhaustion,
        confidence: COVERAGE_LEVEL,
        lower_bound,
        upper_bound,
        rmse,
        sample_count: points.len(),
        window_started_at_unix_micros: first_at,
        window_ended_at_unix_micros: last.at_unix_micros,
    }))
}

/// `least_squares/2` (`model.ex:199-215`). Preserves the **exact** summation order
/// and the `@epsilon` denominator guard so the slope/intercept match bit-for-bit
/// within the parity tolerance.
pub(super) fn least_squares(xs: &[f64], ys: &[f64]) -> (f64, f64) {
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
pub(super) fn residuals(xs: &[f64], ys: &[f64], slope: f64, intercept: f64) -> Vec<f64> {
    xs.iter()
        .zip(ys.iter())
        .map(|(x, y)| y - (intercept + slope * x))
        .collect()
}

/// `rmse/1` (`model.ex:242-250`): `sqrt(sum(r^2) / max(len, 1))`. Empty ⇒ 0.0.
pub(super) fn rmse(residuals: &[f64]) -> f64 {
    if residuals.is_empty() {
        return 0.0;
    }
    let sum_sq: f64 = residuals.iter().map(|r| r * r).sum();
    let denom = residuals.len().max(1) as f64;
    (sum_sq / denom).sqrt()
}

/// Closed-form OLS prediction-interval bounds for a single future point `x0`:
/// `center ± Z·s·sqrt(1 + 1/n + (x0 - x̄)² / Sxx)`, where `s` is the residual standard
/// error (`n-2` df). Unlike the old `± 1.96·RMSE`, the leverage term grows with the
/// extrapolation distance, so a 90-day projection has a strictly wider band than a
/// 7-day one. Degenerate windows (`n < 3`, or a constant `x`) fall back to a
/// zero-width band rather than fabricating one.
pub(super) fn ols_prediction_bounds(
    xs: &[f64],
    residuals: &[f64],
    x0: f64,
    center: f64,
) -> (f64, f64) {
    let n = xs.len();
    if n < 3 {
        return (center, center);
    }
    let nf = n as f64;
    let dof = nf - 2.0;
    let sse: f64 = residuals.iter().map(|r| r * r).sum();
    let s = (sse / dof).sqrt(); // residual standard error (n-2 df)
    let x_mean = xs.iter().sum::<f64>() / nf;
    let sxx: f64 = xs.iter().map(|x| (x - x_mean) * (x - x_mean)).sum();
    let leverage = if sxx > EPSILON {
        1.0 + 1.0 / nf + (x0 - x_mean) * (x0 - x_mean) / sxx
    } else {
        1.0 + 1.0 / nf
    };
    let half_width = Z_0975 * s * leverage.sqrt();
    (center - half_width, center + half_width)
}
