// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The additive Holt-Winters seasonal forecast (`seasonal_forecast/3`,
//! `holt_winters/3`) and its seasonal-initialization / season-map helpers
//! (`model.ex:107-197,314-355`).

use super::exhaustion::{project_seasonal, seasonal_exhaustion_at};
use super::linear::{linear_forecast, rmse};
use super::stats::{mean_abs, stddev, valid_ratio};
use super::types::NormPoint;
use super::{
    COVERAGE_LEVEL, CapacityConfig, EPSILON, MICROS_PER_SECOND, SEASONAL_STRENGTH_THRESHOLD,
    bounded_projection,
};
use crate::disposition::{CapacityForecast, Disposition};

/// `seasonal_forecast/3` (`model.ex:107-112`): Holt-Winters, falling back to linear
/// on insufficient seasonal history (`:not_enough_seasonal_history`).
pub(super) fn seasonal_forecast(points: &[NormPoint], config: &CapacityConfig) -> Disposition {
    match holt_winters(points, config) {
        Some(disposition) => disposition,
        None => linear_forecast(points, config),
    }
}

/// `holt_winters/3` (`model.ex:114-197`). Returns `None` for the
/// `:not_enough_seasonal_history` path (`model.ex:117`), which the caller maps to a
/// linear fallback.
pub(super) fn holt_winters(points: &[NormPoint], config: &CapacityConfig) -> Option<Disposition> {
    let period = config.period;
    // A zero period would bypass this length gate (`period * 2 == 0`, and a `usize`
    // len is never `< 0`) and then panic at `index % period` below; an enormous
    // period would overflow `period * 2` (it wraps to a small value in release,
    // re-bypassing the gate) and then panic in `initial_trend`'s slice. Reject both
    // — `saturating_mul` makes a huge period saturate so the gate trips — so the
    // caller falls back to the linear model. Defense in depth even though the worker
    // normalizes `seasonal_period` to a positive default upstream.
    if period == 0 || points.len() < period.saturating_mul(2) {
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
    let raw_projected_value = project_seasonal(level, trend, &seasons, count, period, steps);
    // `List.last(values)` (model.ex:158).
    let current_value = values[count - 1];
    // `(projected_value - current_value) / horizon_seconds` (model.ex:159). Use
    // the raw fit for ETA/runway; bounds only affect emitted display values.
    let slope = (raw_projected_value - current_value) / horizon_seconds as f64;
    let rmse = rmse(&residuals_vec);
    // Residual-bootstrap 95% prediction interval (off the hot path): simulate
    // `steps`-ahead paths re-injecting resampled in-sample residuals through the same
    // recurrences, then take the 2.5/97.5 quantiles of the horizon endpoints — a
    // valid PI for the additive Holt-Winters path, replacing the old ±1.96·RMSE (D2).
    let (raw_lower, raw_upper) = bootstrap_prediction_bounds(
        level,
        trend,
        &seasons,
        &residuals_vec,
        alpha,
        beta,
        gamma,
        count,
        period,
        steps,
        raw_projected_value,
    );
    let (projected_value, lower_bound, upper_bound, projection_bounded) =
        bounded_projection(config, raw_projected_value, raw_lower, raw_upper);
    let last = points[count - 1];

    let projected_exhaustion = if slope > 0.0 {
        seasonal_exhaustion_at(
            level,
            trend,
            &seasons,
            count,
            period,
            step_seconds,
            threshold,
            last.at_unix_micros,
            steps,
        )
    } else {
        None
    };

    Some(Disposition::Projected(Box::new(CapacityForecast {
        model: "holt_winters_additive".to_string(),
        current_value,
        slope_per_second: slope,
        // `intercept => level` (model.ex:168).
        intercept: level,
        projected_value,
        raw_projected_value,
        projection_bounded,
        projected_exhaustion_at_unix_micros: projected_exhaustion,
        confidence: COVERAGE_LEVEL,
        lower_bound,
        upper_bound,
        rmse,
        sample_count: count,
        window_started_at_unix_micros: first_at,
        window_ended_at_unix_micros: last.at_unix_micros,
    })))
}

/// `median_step_seconds/1` (`model.ex:314-324`). Single point ⇒ 3600; else the
/// median of the consecutive `max(diff_seconds, 1)` gaps (with the
/// `Enum.at(_, mid, 3600)` default for an empty step list).
pub(super) fn median_step_seconds(points: &[NormPoint]) -> i64 {
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
pub(super) fn initial_trend(values: &[f64], period: usize) -> f64 {
    // `Enum.take(values, period)` then `Enum.drop(period) |> Enum.take(period)`.
    let first: &[f64] = &values[..period.min(values.len())];
    let second_start = period.min(values.len());
    // `saturating_add`: an enormous period would otherwise wrap `period + period` to
    // a small value, making `second_end < second_start` and panicking the slice
    // below. Saturating keeps `second_end >= second_start` for any input.
    let second_end = period.saturating_add(period).min(values.len());
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
pub(super) fn initial_seasonals(values: &[f64], period: usize) -> Vec<f64> {
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
pub(super) fn season_at(seasons: &[f64], idx: usize) -> f64 {
    seasons.get(idx).copied().unwrap_or(0.0)
}

/// `Map.put(seasons, idx, value)`: grow the dense season vector with 0.0 padding so
/// an index past the populated head (possible once Holt-Winters writes later
/// buckets) is addressable, matching the Elixir map's insert-anywhere semantics.
pub(super) fn set_season(seasons: &mut Vec<f64>, idx: usize, value: f64) {
    if idx >= seasons.len() {
        seasons.resize(idx + 1, 0.0);
    }
    seasons[idx] = value;
}

/// `seasonal?/2` (`model.ex:346-355`), corrected to derive the seasonal profile
/// from all complete periods instead of only the first period. Seasonal amplitude /
/// total stddev must exceed `@seasonal_strength_threshold`, gated on
/// `total_std > @epsilon`. Fewer than two complete periods ⇒ false.
pub(super) fn is_seasonal(points: &[NormPoint], period: usize) -> bool {
    // A zero period is never seasonal (and would bypass the length gate, then divide
    // by zero in the strength calc). Treat it as non-seasonal so the Auto path picks
    // the linear model. `saturating_mul` so a huge period can't wrap the gate.
    if period == 0 || points.len() < period.saturating_mul(2) {
        return false;
    }
    let values: Vec<f64> = points.iter().map(|p| p.value).collect();
    let seasonals = complete_period_seasonals(&values, period);
    let seasonal_amplitude = mean_abs(&seasonals);
    let complete_len = (values.len() / period) * period;
    let total_std = stddev(&values[..complete_len]);

    total_std > EPSILON && seasonal_amplitude / total_std >= SEASONAL_STRENGTH_THRESHOLD
}

fn complete_period_seasonals(values: &[f64], period: usize) -> Vec<f64> {
    if period == 0 {
        return Vec::new();
    }

    let complete_periods = values.len() / period;
    if complete_periods < 2 {
        return Vec::new();
    }

    let complete_len = complete_periods * period;
    let complete_values = &values[..complete_len];
    let overall_mean = complete_values.iter().sum::<f64>() / complete_len as f64;

    (0..period)
        .map(|slot| {
            let slot_sum: f64 = (0..complete_periods)
                .map(|period_index| complete_values[period_index * period + slot])
                .sum();

            slot_sum / complete_periods as f64 - overall_mean
        })
        .collect()
}

/// Residual-bootstrap prediction-interval bounds for the additive Holt-Winters path.
/// Simulates `steps`-ahead forecast paths from the fitted `(level, trend, seasons)`,
/// re-injecting residuals resampled with replacement from the in-sample one-step
/// residuals and propagating them through the same recurrences; the 2.5/97.5
/// quantiles of the simulated horizon endpoints form the interval. Runs in the
/// periodic capacity Oban job (off the hot path); the draw count scales down for very
/// long horizons so total work stays bounded. Deterministic (seeded) so the forecast
/// is reproducible across runs.
#[allow(clippy::too_many_arguments)]
pub(super) fn bootstrap_prediction_bounds(
    level: f64,
    trend: f64,
    seasons: &[f64],
    residuals: &[f64],
    alpha: f64,
    beta: f64,
    gamma: f64,
    count: usize,
    period: usize,
    steps: i64,
    center: f64,
) -> (f64, f64) {
    if residuals.len() < 2 || steps <= 0 || period == 0 {
        return (center, center);
    }
    let steps = steps as usize;
    // Bound total simulated transitions (~1M) for pathologically long horizons.
    let draws = (1_000_000usize / steps.max(1)).clamp(64, 256);
    let mut rng =
        SplitMix64::new((count as u64).wrapping_mul(0x9E3779B97F4A7C15) ^ 0xD1B54A32D192ED03);
    let mut endpoints: Vec<f64> = Vec::with_capacity(draws);

    for _ in 0..draws {
        let mut lvl = level;
        let mut tr = trend;
        let mut seas = seasons.to_vec();
        let mut last = center;
        for h in 1..=steps {
            let sidx = (count + h - 1) % period;
            let season = season_at(&seas, sidx);
            let point = lvl + tr + season;
            let r = residuals[rng.index(residuals.len())];
            let y = point + r;
            let next_level = alpha * (y - season) + (1.0 - alpha) * (lvl + tr);
            let next_trend = beta * (next_level - lvl) + (1.0 - beta) * tr;
            let next_season = gamma * (y - next_level) + (1.0 - gamma) * season;
            lvl = next_level;
            tr = next_trend;
            set_season(&mut seas, sidx, next_season);
            last = y;
        }
        endpoints.push(last);
    }
    endpoints.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    (quantile(&endpoints, 0.025), quantile(&endpoints, 0.975))
}

/// Linear-interpolated quantile of an ascending-sorted slice.
fn quantile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let pos = q * (sorted.len() - 1) as f64;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    if lo == hi {
        sorted[lo]
    } else {
        sorted[lo] + (pos - lo as f64) * (sorted[hi] - sorted[lo])
    }
}

/// A tiny deterministic SplitMix64 PRNG — no `rand` dependency, reproducible runs.
struct SplitMix64(u64);

impl SplitMix64 {
    fn new(seed: u64) -> Self {
        Self(seed)
    }

    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    fn index(&mut self, n: usize) -> usize {
        (self.next_u64() % n as u64) as usize
    }
}
