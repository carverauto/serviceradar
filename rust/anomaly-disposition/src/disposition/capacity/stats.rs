// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The summary-statistic helpers shared by the linear and seasonal fits: sample
//! stddev, mean-abs, and the Holt-Winters smoothing-ratio guard (`model.ex:372-395`).
//! (The old `confidence/3` heuristic and its `range/1` helper were removed with the
//! prediction-interval rework — D2.)

/// `stddev/1` (`model.ex:372-380`): sample stddev with `max(len - 1, 1)`
/// denominator. Uses `:math.pow(d, 2)` in Elixir; `d * d` is bit-identical for the
/// integer exponent 2 (`pow(x, 2.0) == x*x` for finite x in IEEE-754), so the
/// parity tolerance holds. See RISK note.
pub(super) fn stddev(values: &[f64]) -> f64 {
    let n = values.len().max(1) as f64;
    let mean = values.iter().sum::<f64>() / n;
    // `Enum.map(&:math.pow(&1 - mean, 2)) |> Enum.sum()`.
    let sum_sq: f64 = values.iter().map(|v| (v - mean).powi(2)).sum();
    let denom = (values.len() as i64 - 1).max(1) as f64;
    (sum_sq / denom).sqrt()
}

/// `mean_abs/1` (`model.ex:382-387`): `sum(abs(v)) / max(len, 1)`.
pub(super) fn mean_abs(values: &[f64]) -> f64 {
    let denom = values.len().max(1) as f64;
    let sum: f64 = values.iter().map(|v| v.abs()).sum();
    sum / denom
}

/// `valid_ratio/2` (`model.ex:392-395`): accept a float strictly in `(0.0, 1.0)`,
/// else the default. The worker passes the config ratios; an out-of-range one (or a
/// non-finite one) falls back exactly as Elixir's guard does.
pub(super) fn valid_ratio(value: f64, default: f64) -> f64 {
    if value.is_finite() && value > 0.0 && value < 1.0 {
        value
    } else {
        default
    }
}
