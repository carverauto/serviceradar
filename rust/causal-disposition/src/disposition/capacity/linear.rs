// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The least-squares linear forecast (`linear_forecast/2`) and its supporting
//! least-squares / residual / RMSE helpers (`model.ex:66-105,199-250`).

use super::exhaustion::exhaustion_at;
use super::stats::confidence;
use super::types::NormPoint;
use super::{CapacityConfig, EPSILON, bounded_projection};
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
    let (projected_value, lower_bound, upper_bound, projection_bounded) =
        bounded_projection(config, raw_projected_value, rmse);

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
        confidence: confidence(rmse, &ys, threshold),
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
