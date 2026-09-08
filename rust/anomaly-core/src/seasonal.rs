// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Hour-of-week seasonal baseline primitives shared by the detector core, the
//! `anomaly-backtest` harness, and the edge add-on.
//!
//! A seasonal baseline is a per-series profile of 168 hour-of-week buckets
//! (`dow * 24 + hod`). Each populated bucket carries a *robust* center (a MEDIAN,
//! not a mean — so a single recurring incident hour cannot poison the reference)
//! and a robust dispersion (`scale`, in the metric's own units). The central
//! seasonal-disposition path already computes this profile over the hourly CAGGs
//! (`stats:profile_hour_of_week(value)` → `center` / `mad` / `p05` / `p95`); this
//! module is the edge-side primitive set that turns one delivered bucket back into
//! the [`crate::types::ReasonContext::seasonal_baseline`] the detector consumes.
//!
//! The detector's seasonal signal reduces `seasonal_baseline` via mean/sample-std
//! and z-scores the sample against it ([`crate::signal::evaluate_signal`]). Rather
//! than ship every raw bucket sample, the core delivers the compact robust
//! `{center, scale}` summary and the edge reconstructs a synthetic window whose
//! mean equals `center` and sample standard deviation equals `scale` via
//! [`synthetic_baseline`], so the existing mean/std signal scores
//! `(value - center) / scale` against the robust seasonal reference.

/// Hour-of-week buckets in a profile: 7 days × 24 hours.
pub const HOURS_PER_WEEK: usize = 168;

/// Hour-of-week bucket (`0..=167`, `dow * 24 + hod`) for a unix-nanosecond
/// timestamp, UTC. 1970-01-01 was a Thursday (`dow = 4`), so
/// `dow = (days + 4) mod 7`. Mirrors the `anomaly-backtest` harness so the edge
/// and the harness bucket a sample identically.
pub fn hour_of_week(observed_at_unix_nano: u64) -> usize {
    let secs = (observed_at_unix_nano / 1_000_000_000) as i64;
    let dow = ((secs.div_euclid(86_400) + 4).rem_euclid(7)) as usize;
    let hod = (secs.rem_euclid(86_400) / 3_600) as usize;
    dow * 24 + hod
}

/// One hour-of-week bucket's robust seasonal baseline, delivered from core.
///
/// `center` is the bucket's robust center (the MEDIAN of its historical values);
/// `scale` is a robust dispersion in the metric's own units (e.g. `mad * 1.4826`,
/// or `(p95 - p05) / (2 * 1.6449)`); `sample_count` is how many historical points
/// (weeks of observation) backed the bucket, used to gate readiness so a bucket
/// with too little history is not trusted.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SeasonalBucket {
    pub center: f64,
    pub scale: f64,
    pub sample_count: usize,
}

impl SeasonalBucket {
    /// A bucket is usable as a baseline only when its center is finite, its scale
    /// is finite and non-negative, and it was backed by at least
    /// `min_sample_count` historical points. A bucket failing this is treated as
    /// undelivered (the series scores without a seasonal signal — the back-compat
    /// behavior).
    pub fn usable(&self, min_sample_count: usize) -> bool {
        self.center.is_finite()
            && self.scale.is_finite()
            && self.scale >= 0.0
            && self.sample_count >= min_sample_count.max(1)
    }

    /// Reconstruct the synthetic seasonal window for this bucket — see
    /// [`synthetic_baseline`].
    pub fn synthetic_window(&self, len: usize) -> Vec<f64> {
        synthetic_baseline(self.center, self.scale, len)
    }
}

/// Reconstruct a synthetic baseline window of `len` points whose mean equals
/// `center` and whose sample standard deviation (the `n - 1` divisor used by
/// [`crate::stats::sample_stats`]) equals `scale`, so the detector's mean/std
/// seasonal signal scores `(value - center) / scale` against the delivered robust
/// summary without the core needing a new precomputed-stats baseline shape.
///
/// The points alternate `center ± d` (with an extra `center` point for an odd
/// `len`) so the mean is exactly `center`; `d` is chosen so the sample std is
/// exactly `scale`. A non-positive or non-finite `scale` yields a constant window
/// (the detector's near-zero dispersion guard then governs scoring).
pub fn synthetic_baseline(center: f64, scale: f64, len: usize) -> Vec<f64> {
    let n = len.max(2);

    if !scale.is_finite() || scale <= 0.0 || !center.is_finite() {
        return vec![center; n];
    }

    let mut out = Vec::with_capacity(n);
    if n.is_multiple_of(2) {
        // n even: n/2 pairs of (center - d, center + d). Sample variance is
        // n*d^2 / (n - 1), so d = scale * sqrt((n - 1) / n) makes it exactly scale^2.
        let d = scale * (((n - 1) as f64) / (n as f64)).sqrt();
        for i in 0..n {
            out.push(if i % 2 == 0 { center - d } else { center + d });
        }
    } else {
        // n odd: (n - 1) paired points at center ± scale plus one center point.
        // Sample variance is (n - 1)*scale^2 / (n - 1) = scale^2 exactly.
        for i in 0..(n - 1) {
            out.push(if i % 2 == 0 {
                center - scale
            } else {
                center + scale
            });
        }
        out.push(center);
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::sample_stats;

    #[test]
    fn hour_of_week_is_dow_times_24_plus_hod_utc() {
        // 1970-01-01 00:00:00 UTC is a Thursday (dow 4), hour 0 -> 4*24 + 0 = 96.
        assert_eq!(hour_of_week(0), 96);
        // +1 hour -> hod 1.
        assert_eq!(hour_of_week(3_600 * 1_000_000_000), 97);
        // +1 day -> Friday (dow 5), hod 0 -> 120.
        assert_eq!(hour_of_week(86_400 * 1_000_000_000), 120);
        // +3 days -> Sunday (dow 0), hod 0 -> 0.
        assert_eq!(hour_of_week(3 * 86_400 * 1_000_000_000), 0);
        assert!(hour_of_week(u64::MAX) < HOURS_PER_WEEK);
    }

    #[test]
    fn synthetic_baseline_reproduces_center_and_scale_even_len() {
        let window = synthetic_baseline(70.0, 4.0, 30);
        assert_eq!(window.len(), 30);
        let stats = sample_stats(&window);
        assert!((stats.mean - 70.0).abs() < 1e-9, "mean {}", stats.mean);
        assert!((stats.stddev - 4.0).abs() < 1e-9, "stddev {}", stats.stddev);
    }

    #[test]
    fn synthetic_baseline_reproduces_center_and_scale_odd_len() {
        let window = synthetic_baseline(12.5, 0.75, 31);
        assert_eq!(window.len(), 31);
        let stats = sample_stats(&window);
        assert!((stats.mean - 12.5).abs() < 1e-9, "mean {}", stats.mean);
        assert!(
            (stats.stddev - 0.75).abs() < 1e-9,
            "stddev {}",
            stats.stddev
        );
    }

    #[test]
    fn synthetic_baseline_degenerate_scale_is_constant() {
        let window = synthetic_baseline(50.0, 0.0, 8);
        assert_eq!(window, vec![50.0; 8]);
        let nan = synthetic_baseline(50.0, f64::NAN, 4);
        assert_eq!(nan, vec![50.0; 4]);
    }

    #[test]
    fn bucket_usable_gates_on_history_and_finiteness() {
        let ready = SeasonalBucket {
            center: 70.0,
            scale: 4.0,
            sample_count: 8,
        };
        assert!(ready.usable(4));
        assert!(!ready.usable(9), "too few historical points is not usable");

        let bad_scale = SeasonalBucket {
            center: 70.0,
            scale: f64::NAN,
            sample_count: 8,
        };
        assert!(!bad_scale.usable(4));
    }
}
