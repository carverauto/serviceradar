// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Welford rolling statistics and the z-score breach function.

const NEAR_ZERO_STDDEV: f64 = 1.0e-9;
const IMPLICIT_ZERO_VARIANCE_CV: f64 = 0.10;
const IMPLICIT_ZERO_VARIANCE_MIN_FLOOR: f64 = 1.0;

/// A computed baseline: mean and standard deviation of a window of samples.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BaselineStats {
    pub mean: f64,
    pub stddev: f64,
}

impl BaselineStats {
    /// The dispersion the z-score divides by, raised to a configured floor so a
    /// near-constant series (e.g. disk used_percent ~1.36% ± 0.01) cannot turn a
    /// trivial wiggle into a large z-score. The effective dispersion is the max
    /// of the raw stddev, an absolute floor (`min_std_floor`, in the metric's own
    /// units), and a relative floor (`min_cv * |mean|`, a coefficient-of-variation
    /// floor that scales with the level). Both floors default to ~0 so untuned
    /// series keep the prior pure-stddev behavior.
    pub fn effective_stddev(&self, min_std_floor: f64, min_cv: f64) -> f64 {
        let abs_floor = if min_std_floor.is_finite() && min_std_floor > 0.0 {
            min_std_floor
        } else {
            0.0
        };
        let cv_floor = if min_cv.is_finite() && min_cv > 0.0 {
            min_cv * self.mean.abs()
        } else {
            0.0
        };
        self.stddev.max(abs_floor).max(cv_floor)
    }
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
            self.count = self.count.saturating_add(1);
            self.mean = f64::NAN;
            self.m2 = f64::NAN;
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
    let mut count = 0usize;
    let mut sum = 0.0;

    for value in values.iter().copied().filter(|value| value.is_finite()) {
        count = count.saturating_add(1);
        sum += value;
    }

    if count == 0 {
        return BaselineStats {
            mean: 0.0,
            stddev: 0.0,
        };
    }

    let mean = sum / count as f64;

    if count == 1 {
        return BaselineStats { mean, stddev: 0.0 };
    }

    let variance = values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .map(|value| {
            let delta = value - mean;
            delta * delta
        })
        .sum::<f64>()
        / (count as f64 - 1.0);

    BaselineStats {
        mean,
        stddev: variance.max(0.0).sqrt(),
    }
}

/// The breach score for `sample_value` against a baseline. Returns the absolute
/// z-score in the normal case; for a zero/near-zero-variance baseline it uses an
/// implicit 10%-of-level dispersion floor. That keeps a floor-less counter rate
/// from firing Critical on a single tick while still letting a material jump
/// breach.
///
/// `min_std_floor` / `min_cv` raise the effective dispersion before dividing
/// (see [`BaselineStats::effective_stddev`]); pass `0.0` for both to recover the
/// prior pure-stddev behavior. When the floored dispersion is positive it is used
/// directly — a near-constant series with a *tiny but nonzero* stddev no longer
/// produces a huge z-score from a trivial wiggle (the live disk-1.36% false-fire).
pub fn z_score(
    sample_value: f64,
    stats: BaselineStats,
    _threshold: f64,
    min_std_floor: f64,
    min_cv: f64,
) -> f64 {
    let effective_stddev = stats.effective_stddev(min_std_floor, min_cv);

    if effective_stddev <= NEAR_ZERO_STDDEV {
        let deviation = (sample_value - stats.mean).abs();
        if deviation <= NEAR_ZERO_STDDEV {
            0.0
        } else {
            let floor = (stats.mean.abs() * IMPLICIT_ZERO_VARIANCE_CV)
                .max(IMPLICIT_ZERO_VARIANCE_MIN_FLOOR);
            deviation / floor
        }
    } else {
        ((sample_value - stats.mean) / effective_stddev).abs()
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
    fn zero_variance_score_uses_magnitude_floor() {
        let stats = BaselineStats {
            mean: 100.0,
            stddev: 0.0,
        };
        let threshold = 3.0;

        let small = z_score(101.0, stats, threshold, 0.0, 0.0);
        let large = z_score(10_000.0, stats, threshold, 0.0, 0.0);

        assert!(
            small < threshold,
            "small deviation must not auto-breach a zero-variance baseline"
        );
        assert!(large >= threshold, "large deviation must still breach");
        assert!(
            large > small,
            "large deviation ({large}) must outrank small deviation ({small})"
        );
    }

    #[test]
    fn zero_variance_no_deviation_scores_zero() {
        let stats = BaselineStats {
            mean: 42.0,
            stddev: 0.0,
        };
        assert_eq!(z_score(42.0, stats, 3.0, 0.0, 0.0), 0.0);
    }

    #[test]
    fn zero_variance_zero_mean_ranks_by_magnitude() {
        let stats = BaselineStats {
            mean: 0.0,
            stddev: 0.0,
        };
        let threshold = 3.0;
        let small = z_score(1.0, stats, threshold, 0.0, 0.0);
        let large = z_score(1_000_000.0, stats, threshold, 0.0, 0.0);

        assert!(small < threshold);
        assert!(large > small);
        assert!(large >= threshold);
        assert!(small.is_finite() && large.is_finite());
    }

    #[test]
    fn sample_stats_is_defined_for_empty_and_singleton_windows() {
        let empty = sample_stats(&[]);
        assert_eq!(empty.mean, 0.0);
        assert_eq!(empty.stddev, 0.0);
        assert!(empty.mean.is_finite() && empty.stddev.is_finite());

        let singleton = sample_stats(&[42.0]);
        assert_eq!(singleton.mean, 42.0);
        assert_eq!(singleton.stddev, 0.0);
        assert!(singleton.mean.is_finite() && singleton.stddev.is_finite());
    }

    #[test]
    fn welford_non_finite_input_invalidates_instead_of_silent_drop() {
        let mut acc = WelfordAcc::default();
        acc.add(10.0);
        acc.add(f64::NAN);

        assert_eq!(acc.count, 2, "logical sample count must advance");
        assert!(!acc.valid_for_count(2));
        assert!(acc.stats().is_none());
    }

    #[test]
    fn min_std_floor_collapses_near_constant_wiggle() {
        // The live false-fire: disk used_percent hovering at ~1.36% with ~0.01
        // jitter has a tiny *nonzero* stddev, so the unfloored z-score on a
        // 0.1-point bump is enormous. A 1.0-point absolute floor (percent units)
        // collapses it to well under any sane sigma threshold.
        let stats = BaselineStats {
            mean: 1.36,
            stddev: 0.012,
        };
        let unfloored = z_score(1.46, stats, 3.0, 0.0, 0.0);
        let floored = z_score(1.46, stats, 3.0, 1.0, 0.05);

        assert!(
            unfloored > 3.0,
            "premise: unfloored z {unfloored} must breach (the bug)"
        );
        assert!(
            floored < 1.0,
            "floored z {floored} must be tiny so a benign wiggle never breaches"
        );
    }

    #[test]
    fn min_cv_floor_scales_with_level() {
        // A relative (coefficient-of-variation) floor scales with the mean, so a
        // high-magnitude series with proportionally small jitter is also tamed.
        let stats = BaselineStats {
            mean: 1_000.0,
            stddev: 2.0,
        };
        // 5%-of-mean CV floor = 50 dispersion; a +10 bump is z=0.2, not z=5.
        let floored = z_score(1_010.0, stats, 3.0, 0.0, 0.05);
        assert!(floored < 1.0, "cv-floored z {floored} must be small");
    }

    #[test]
    fn floor_does_not_mask_a_genuine_large_excursion() {
        // The floor lifts the denominator but a real spike still clears it: a
        // 10x jump on the disk series breaches even with the percent-unit floor.
        let stats = BaselineStats {
            mean: 1.36,
            stddev: 0.012,
        };
        let big = z_score(15.0, stats, 3.0, 1.0, 0.05);
        assert!(big >= 3.0, "a true excursion {big} must still breach");
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
