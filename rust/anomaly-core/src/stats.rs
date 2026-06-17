// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Welford rolling statistics and the z-score breach function.

/// A computed baseline: mean and standard deviation of a window of samples.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BaselineStats {
    pub mean: f64,
    pub stddev: f64,
}

/// Online Welford accumulator supporting O(1) add and remove, so a rolling
/// window's mean/variance can be maintained incrementally as samples enter and
/// leave the window.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct WelfordAcc {
    pub count: usize,
    pub mean: f64,
    pub m2: f64,
}

impl WelfordAcc {
    pub fn from_values(values: &[f64]) -> Self {
        values
            .iter()
            .copied()
            .fold(Self::default(), |mut acc, value| {
                acc.add(value);
                acc
            })
    }

    pub fn add(&mut self, value: f64) {
        if !value.is_finite() {
            return;
        }

        let next_count = self.count.saturating_add(1);
        let delta = value - self.mean;

        self.count = next_count;
        self.mean += delta / next_count as f64;
        let delta_after = value - self.mean;
        self.m2 += delta * delta_after;

        if self.m2 < 0.0 {
            self.m2 = 0.0;
        }
    }

    pub fn remove(&mut self, value: f64) {
        if !value.is_finite() || self.count == 0 {
            return;
        }

        if self.count == 1 {
            *self = Self::default();
            return;
        }

        let old_count = self.count as f64;
        let next_count = self.count - 1;
        let next_count_f64 = next_count as f64;
        let old_mean = self.mean;
        let next_mean = (old_count * old_mean - value) / next_count_f64;

        self.count = next_count;
        self.mean = next_mean;
        self.m2 -= (value - old_mean) * (value - next_mean);

        // A would-be-negative m2 used to be silently clamped to 0.0, which hides
        // genuine numerical drift (e.g. from large-counter catastrophic
        // cancellation) behind a fabricated zero-variance baseline. Tiny
        // negatives within rounding tolerance are still benign and clamped;
        // anything larger marks the acc invalid (NAN m2) so `valid_for_count` /
        // `stats` fail and the caller rebuilds from the retained window tail,
        // which is always available and cheap to recompute.
        if self.m2 < 0.0 {
            let drift_tolerance = f64::EPSILON
                * (self.m2.abs().max(old_mean.abs()).max(value.abs()).max(1.0))
                * old_count;
            if self.m2 >= -drift_tolerance {
                self.m2 = 0.0;
            } else {
                self.m2 = f64::NAN;
            }
        }
    }

    pub fn valid_for_count(self, count: usize) -> bool {
        self.count == count
            && self.mean.is_finite()
            && self.m2.is_finite()
            && self.m2 >= 0.0
            && (count != 0 || (self.mean == 0.0 && self.m2 == 0.0))
    }

    pub fn stats(self) -> Option<BaselineStats> {
        if self.count < 2 || !self.mean.is_finite() || !self.m2.is_finite() {
            return None;
        }

        let variance = self.m2.max(0.0) / (self.count as f64 - 1.0);

        Some(BaselineStats {
            mean: self.mean,
            stddev: variance.sqrt(),
        })
    }
}

/// Two-pass mean/variance for a full slice (used to rebuild a baseline from a
/// retained window tail when the incremental accumulator is invalidated).
pub fn sample_stats(values: &[f64]) -> BaselineStats {
    let count = values.len() as f64;
    let mean = values.iter().sum::<f64>() / count;
    let variance = values
        .iter()
        .map(|value| {
            let delta = value - mean;
            delta * delta
        })
        .sum::<f64>()
        / (count - 1.0);

    BaselineStats {
        mean,
        stddev: variance.max(0.0).sqrt(),
    }
}

/// The breach score for `sample_value` against a baseline. Returns the absolute
/// z-score in the normal case; for a zero-variance baseline it returns a
/// magnitude-aware score that always clears `threshold` on any deviation but
/// grows with the relative excursion so larger spikes outrank smaller ones.
pub fn z_score(sample_value: f64, stats: BaselineStats, threshold: f64) -> f64 {
    if stats.stddev <= f64::EPSILON {
        let deviation = (sample_value - stats.mean).abs();
        if deviation <= f64::EPSILON {
            0.0
        } else {
            let floor = stats.mean.abs().max(1.0) * f64::EPSILON.sqrt();
            let magnitude = (deviation / floor).max(0.0);
            (threshold + 1.0) + magnitude.ln_1p()
        }
    } else {
        ((sample_value - stats.mean) / stats.stddev).abs()
    }
}

/// Normalize a configured threshold, falling back to [`crate::DEFAULT_N_SIGMA`]
/// when it is non-finite or non-positive.
pub fn clean_threshold(threshold: f64) -> f64 {
    if threshold.is_finite() && threshold > 0.0 {
        threshold
    } else {
        crate::DEFAULT_N_SIGMA
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_variance_score_is_magnitude_aware() {
        let stats = BaselineStats {
            mean: 100.0,
            stddev: 0.0,
        };
        let threshold = 3.0;

        let small = z_score(101.0, stats, threshold);
        let large = z_score(10_000.0, stats, threshold);

        assert!(small >= threshold, "small deviation must still breach");
        assert!(large >= threshold, "large deviation must still breach");
        assert!(
            large > small,
            "large deviation ({large}) must outrank small deviation ({small})"
        );
        assert!(small >= threshold + 1.0);
    }

    #[test]
    fn zero_variance_no_deviation_scores_zero() {
        let stats = BaselineStats {
            mean: 42.0,
            stddev: 0.0,
        };
        assert_eq!(z_score(42.0, stats, 3.0), 0.0);
    }

    #[test]
    fn zero_variance_zero_mean_ranks_by_magnitude() {
        let stats = BaselineStats {
            mean: 0.0,
            stddev: 0.0,
        };
        let threshold = 3.0;
        let small = z_score(1.0, stats, threshold);
        let large = z_score(1_000_000.0, stats, threshold);

        assert!(small >= threshold);
        assert!(large > small);
        assert!(small.is_finite() && large.is_finite());
    }

    #[test]
    fn remove_tolerates_rounding_scale_negative_m2() {
        let mut acc = WelfordAcc::from_values(&[5.0, 5.0, 5.0, 5.0]);
        acc.remove(5.0);
        assert!(
            acc.m2.is_finite(),
            "benign drift must not invalidate the acc"
        );
        assert!(acc.valid_for_count(acc.count));
    }

    #[test]
    fn remove_large_negative_m2_forces_recompute() {
        let mut acc = WelfordAcc::from_values(&[1.0, 2.0, 3.0, 4.0, 5.0]);
        acc.m2 = 1.0e-9;
        acc.remove(5.0);

        assert!(
            !acc.m2.is_finite(),
            "drift past tolerance must invalidate m2"
        );
        assert!(
            !acc.valid_for_count(acc.count),
            "an invalidated acc must fail validation so the caller recomputes"
        );
        assert!(acc.stats().is_none());
    }

    #[test]
    fn rolling_add_remove_matches_two_pass() {
        let mut acc = WelfordAcc::default();
        for v in [10.0, 12.0, 11.0, 13.0, 9.0, 14.0] {
            acc.add(v);
        }
        acc.remove(10.0);
        acc.add(15.0);
        let tail = [12.0, 11.0, 13.0, 9.0, 14.0, 15.0];
        let two_pass = sample_stats(&tail);
        let incremental = acc.stats().expect("ready baseline");
        assert!((incremental.mean - two_pass.mean).abs() < 1e-9);
        assert!((incremental.stddev - two_pass.stddev).abs() < 1e-9);
    }
}
