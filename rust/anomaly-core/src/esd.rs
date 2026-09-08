// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Seasonal-Hybrid ESD (S-H-ESD) primitives: the Generalized ESD (Rosner) test using
//! a robust median/MAD center/scale (the "Hybrid"), plus the normal and Student-t
//! inverse-CDF helpers its critical values need.
//!
//! S-H-ESD is the standard time-series anomaly test (Twitter AnomalyDetection): STL/
//! hour-of-week DESEASONALIZES the series, then Generalized ESD on the residual finds
//! up to `k` outliers while CONTROLLING the family-wise error rate (a plain per-point
//! z-test does not). This module implements the ESD half; the caller supplies the
//! already-deseasonalized residual series. The Hybrid variant uses median + MAD in the
//! R_i statistic so a past incident does not inflate the dispersion and mask later
//! outliers.

/// Inverse standard-normal CDF (Acklam's rational approximation; |abs err| < 1.15e-9
/// over the central region, refined nowhere here — accurate to ~1e-4 at the tails we
/// use). Verified in tests against `Φ⁻¹(0.975) = 1.959964`.
pub fn norm_ppf(p: f64) -> f64 {
    const A: [f64; 6] = [
        -3.969683028665376e+01,
        2.209460984245205e+02,
        -2.759285104469687e+02,
        1.38357751867269e+02,
        -3.066479806614716e+01,
        2.506628277459239e+00,
    ];
    const B: [f64; 5] = [
        -5.447609879822406e+01,
        1.615858368580409e+02,
        -1.556989798598866e+02,
        6.680131188771972e+01,
        -1.328068155288572e+01,
    ];
    const C: [f64; 6] = [
        -7.784894002430293e-03,
        -3.223964580411365e-01,
        -2.400758277161838e+00,
        -2.549732539343734e+00,
        4.374664141464968e+00,
        2.938163982698783e+00,
    ];
    const D: [f64; 4] = [
        7.784695709041462e-03,
        3.224671290700398e-01,
        2.445134137142996e+00,
        3.754408661907416e+00,
    ];
    const PLOW: f64 = 0.02425;
    const PHIGH: f64 = 1.0 - PLOW;

    if p <= 0.0 {
        return f64::NEG_INFINITY;
    }
    if p >= 1.0 {
        return f64::INFINITY;
    }
    if p < PLOW {
        let q = (-2.0 * p.ln()).sqrt();
        (((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    } else if p <= PHIGH {
        let q = p - 0.5;
        let r = q * q;
        (((((A[0] * r + A[1]) * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * q
            / (((((B[0] * r + B[1]) * r + B[2]) * r + B[3]) * r + B[4]) * r + 1.0)
    } else {
        let q = (-2.0 * (1.0 - p).ln()).sqrt();
        -(((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    }
}

/// Student-t inverse CDF via a Cornish-Fisher expansion off the normal quantile.
/// Accurate for `df >= ~6` (the ESD profiles have df in the tens–hundreds). Verified
/// against `t(0.975, 10) ≈ 2.2281` and `t(0.975, ∞) → z`.
pub fn t_ppf(p: f64, df: f64) -> f64 {
    let z = norm_ppf(p);
    if !df.is_finite() || df <= 0.0 {
        return z;
    }
    let z2 = z * z;
    let z3 = z2 * z;
    let z5 = z3 * z2;
    let z7 = z5 * z2;
    let z9 = z7 * z2;
    let g1 = (z3 + z) / 4.0;
    let g2 = (5.0 * z5 + 16.0 * z3 + 3.0 * z) / 96.0;
    let g3 = (3.0 * z7 + 19.0 * z5 + 17.0 * z3 - 15.0 * z) / 384.0;
    let g4 = (79.0 * z9 + 776.0 * z7 + 1482.0 * z5 - 1920.0 * z3 - 945.0 * z) / 92160.0;
    z + g1 / df + g2 / (df * df) + g3 / (df * df * df) + g4 / (df * df * df * df)
}

fn median_sorted(sorted: &[f64]) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    if n % 2 == 1 {
        sorted[n / 2]
    } else {
        (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}

fn median(values: &[f64]) -> f64 {
    let mut v = values.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    median_sorted(&v)
}

/// Median absolute deviation rescaled to a stddev-equivalent (×1.4826).
fn mad_scale(values: &[f64], center: f64) -> f64 {
    let dev: Vec<f64> = values.iter().map(|v| (v - center).abs()).collect();
    median(&dev) * 1.482_602_218_505_602
}

/// Generalized ESD (Rosner) with a robust median/MAD center/scale (S-H-ESD's Hybrid).
/// Returns the indices (into `values`) of the detected outliers — at most
/// `max_outliers`, controlling the family-wise error at level `alpha`.
///
/// For each step `i` (1..=k) it removes the point with the largest robust deviation
/// `R_i = max|x - median| / (MAD·1.4826)`, then compares `R_i` to the Rosner critical
/// value `λ_i`; the outlier count is the largest `i` with `R_i > λ_i`.
pub fn generalized_esd(values: &[f64], max_outliers: usize, alpha: f64) -> Vec<usize> {
    let n = values.len();
    if n < 3 || max_outliers == 0 {
        return Vec::new();
    }
    let k = max_outliers.min(n - 2);
    let mut remaining: Vec<usize> = (0..n).collect();
    let mut removed: Vec<usize> = Vec::with_capacity(k);
    let mut r_stats: Vec<f64> = Vec::with_capacity(k);
    let mut lambdas: Vec<f64> = Vec::with_capacity(k);

    for i in 0..k {
        let cur: Vec<f64> = remaining.iter().map(|&j| values[j]).collect();
        let center = median(&cur);
        let scale = {
            let s = mad_scale(&cur, center);
            if s > 1e-12 {
                s
            } else {
                stddev(&cur).max(1e-12)
            }
        };

        // point with the maximum robust deviation
        let mut best_pos = 0usize;
        let mut best_r = f64::NEG_INFINITY;
        for (pos, &j) in remaining.iter().enumerate() {
            let r = (values[j] - center).abs() / scale;
            if r > best_r {
                best_r = r;
                best_pos = pos;
            }
        }
        r_stats.push(best_r);
        removed.push(remaining[best_pos]);

        // Rosner critical value λ_i with n_i remaining points (1-indexed step i+1).
        let n_i = (n - i) as f64;
        let p = 1.0 - alpha / (2.0 * n_i);
        let df = n_i - 2.0;
        let t = t_ppf(p, df);
        let lambda = ((n_i - 1.0) * t) / ((df + t * t) * n_i).sqrt();
        lambdas.push(lambda);

        remaining.remove(best_pos);
    }

    let mut num = 0usize;
    for i in 0..r_stats.len() {
        if r_stats[i] > lambdas[i] {
            num = i + 1;
        }
    }
    removed.into_iter().take(num).collect()
}

/// Seasonal-Hybrid ESD: deseasonalize the series by subtracting the per-phase
/// (`i mod period`) MEDIAN, then run [`generalized_esd`] on the residuals. This is the
/// full S-H-ESD: the robust seasonal estimate removes the periodic component so the
/// ESD scores genuine off-pattern excursions, and the median front-end (not a mean)
/// keeps a past incident from biasing the seasonal estimate. Returns anomaly indices
/// into the original series.
pub fn seasonal_hybrid_esd(
    values: &[f64],
    period: usize,
    max_outliers: usize,
    alpha: f64,
) -> Vec<usize> {
    if period == 0 || values.len() < period {
        return generalized_esd(values, max_outliers, alpha);
    }
    let mut phase: Vec<Vec<f64>> = vec![Vec::new(); period];
    for (i, &v) in values.iter().enumerate() {
        phase[i % period].push(v);
    }
    let phase_median: Vec<f64> = phase.iter().map(|p| median(p)).collect();
    let residual: Vec<f64> = values
        .iter()
        .enumerate()
        .map(|(i, &v)| v - phase_median[i % period])
        .collect();
    generalized_esd(&residual, max_outliers, alpha)
}

fn stddev(values: &[f64]) -> f64 {
    let n = values.len();
    if n < 2 {
        return 0.0;
    }
    let mean = values.iter().sum::<f64>() / n as f64;
    let var = values.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>() / (n as f64 - 1.0);
    var.sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normal_quantile_matches_reference() {
        assert!((norm_ppf(0.975) - 1.959_963_98).abs() < 1e-4);
        assert!((norm_ppf(0.95) - 1.644_853_63).abs() < 1e-4);
        assert!((norm_ppf(0.5)).abs() < 1e-6);
        assert!((norm_ppf(0.025) + 1.959_963_98).abs() < 1e-4); // symmetric
    }

    #[test]
    fn t_quantile_matches_reference() {
        // t(0.975, 10) = 2.2281; t(0.975, 30) = 2.0423; large df -> z.
        assert!((t_ppf(0.975, 10.0) - 2.2281).abs() < 5e-3);
        assert!((t_ppf(0.975, 30.0) - 2.0423).abs() < 5e-3);
        assert!((t_ppf(0.975, 100_000.0) - 1.959_964).abs() < 1e-3);
    }

    #[test]
    fn gesd_finds_the_injected_outliers() {
        // 40 tightly-clustered points around 10 + 3 clear outliers.
        let mut v: Vec<f64> = Vec::new();
        for i in 0..40 {
            v.push(10.0 + ((i % 5) as f64 - 2.0) * 0.1); // ~[9.8, 10.2]
        }
        v.push(25.0); // outlier idx 40
        v.push(26.0); // outlier idx 41
        v.push(24.0); // outlier idx 42
        let mut out = generalized_esd(&v, 10, 0.05);
        out.sort_unstable();
        assert_eq!(
            out,
            vec![40, 41, 42],
            "GESD should find exactly the 3 outliers"
        );
    }

    #[test]
    fn gesd_clean_series_finds_nothing() {
        let v: Vec<f64> = (0..50)
            .map(|i| 5.0 + ((i % 7) as f64 - 3.0) * 0.05)
            .collect();
        assert!(
            generalized_esd(&v, 5, 0.05).is_empty(),
            "a clean series must yield no outliers"
        );
    }

    #[test]
    fn seasonal_hybrid_esd_finds_offpattern_anomalies_not_the_season() {
        // Strong period-24 seasonal pattern; a RAW ESD would drown in the seasonal
        // swing, but after deseasonalization only the injected off-pattern spikes
        // remain. 5 full periods (120 points) + 2 spikes placed at LOW-season phases.
        let period = 24;
        let mut v: Vec<f64> = (0..120)
            .map(|i| {
                let phase = (i % period) as f64;
                50.0 + 20.0 * (2.0 * std::f64::consts::PI * phase / period as f64).sin()
            })
            .collect();
        // inject two off-pattern spikes at the same phase but different periods; a
        // high reading is flagged only AFTER the per-phase median deseasonalization
        v[6] = 90.0; // phase 6, period 0
        v[78] = 88.0; // phase 6, period 3
        let mut out = seasonal_hybrid_esd(&v, period, 6, 0.05);
        out.sort_unstable();
        assert_eq!(
            out,
            vec![6, 78],
            "S-H-ESD should flag the off-pattern spikes only"
        );
    }

    #[test]
    fn seasonal_hybrid_esd_ignores_recurring_peaks_that_raw_esd_flags() {
        // 2.9 comparison: a sharp peak recurs every period (a normal "nightly backup"),
        // plus one genuine off-pattern anomaly. Raw ESD flags the recurring peaks as the
        // series extremes (false positives); S-H-ESD deseasonalizes first, so it flags
        // ONLY the genuine off-pattern point — the seasonal-hybrid advantage.
        let period = 24;
        let mut v: Vec<f64> = vec![50.0; 5 * period];
        for p in 0..5 {
            v[p * period + 12] = 100.0; // recurring seasonal peak (normal)
        }
        v[2 * period + 3] = 90.0; // genuine off-pattern anomaly

        let raw = generalized_esd(&v, 8, 0.05);
        assert!(
            raw.iter().any(|&i| i % period == 12),
            "a RAW ESD wrongly flags the recurring seasonal peaks as extremes"
        );

        let sh = seasonal_hybrid_esd(&v, period, 8, 0.05);
        assert_eq!(
            sh,
            vec![2 * period + 3],
            "S-H-ESD flags only the genuine off-pattern anomaly, not the recurring season"
        );
    }
}
