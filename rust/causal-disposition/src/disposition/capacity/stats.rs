// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The summary-statistic helpers shared by the linear and seasonal fits:
//! confidence scaling, range, sample stddev, mean-abs, and the Holt-Winters
//! smoothing-ratio guard (`model.ex:357-395`).

use super::EPSILON;

/// `confidence/3` (`model.ex:357-368`): `clamp(1.0 - rmse/scale, 0.0, 1.0)` with the
/// threshold/range/mean scale fallback chain.
///
/// PARITY: the clamp is the manual `max(0.0) |> min(1.0)` (`model.ex:365-367`), NOT
/// a single `f64::clamp`. They diverge on NaN — `(NaN).max(0.0).min(1.0) == 0.0`
/// (both Rust's and Elixir's `max`/`min` drop the NaN operand and return the bound)
/// while `clamp` propagates NaN — so the manual form is required for parity. The
/// `manual_clamp` lint is allowed for exactly that reason; do NOT switch to `clamp`.
#[allow(clippy::manual_clamp)]
pub(super) fn confidence(rmse: f64, values: &[f64], threshold: Option<f64>) -> f64 {
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
pub(super) fn range(values: &[f64]) -> f64 {
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
