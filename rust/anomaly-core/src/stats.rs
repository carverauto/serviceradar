// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Welford rolling statistics and the z-score breach function.

/// When a baseline has zero or near-zero dispersion and no explicit per-series
/// floor, use a magnitude-aware denominator instead of `f64::EPSILON`. A 1-unit
/// guard is only appropriate for a truly zero baseline; nonzero small-rate
/// series must scale by their own level or real sub-1.0 excursions disappear.
const NEAR_ZERO_STDDEV_ABS_FLOOR: f64 = 1.0;
const NEAR_ZERO_STDDEV_REL_FLOOR: f64 = 0.05;

/// Normal-consistency constant for the median absolute deviation: `MAD * 1.4826`
/// is a consistent estimator of the standard deviation of a Gaussian
/// (`1 / Φ⁻¹(0.75) ≈ 1.4826`), so a robust median/MAD scale is directly
/// comparable to a mean/std `stddev` and the same n-sigma threshold applies.
pub const MAD_TO_SIGMA: f64 = 1.4826;

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

/// A robust baseline: the MEDIAN center and a MAD-derived scale, i.e. the Hampel
/// identifier's dispersion. This is the edge detector's primary dispersion
/// estimator (replacing mean/std) because it does not self-mask: the median and
/// MAD have a 50% breakdown point, so a single large spike in the window cannot
/// inflate the center/scale enough to hide a second spike of similar magnitude
/// (the failure mode a mean/std baseline has, where the first spike's variance
/// swallows the second).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RobustStats {
    /// The window median — the robust center the deviation subtracts.
    pub center: f64,
    /// `median(|x_i - center|) * 1.4826` — the normal-consistency-scaled median
    /// absolute deviation, the robust analogue of the standard deviation. This is
    /// `0` for a pinned/discrete window (more than half the samples identical);
    /// the dispersion floors then lift it to a safe denominator before scoring.
    pub scale: f64,
}

impl RobustStats {
    /// Compute the median center and `MAD * 1.4826` scale over a window. Non-finite
    /// samples are dropped. An empty window is `{0, 0}`; a singleton is
    /// `{value, 0}` (no dispersion). O(n log n) — one sort for the median and one
    /// for the MAD; this is the deliberate cost of the robust estimator over the
    /// O(1)-updatable Welford mean/std (the window path rebuilds per evaluation).
    pub fn from_values(values: &[f64]) -> Self {
        let mut sorted = values
            .iter()
            .copied()
            .filter(|value| value.is_finite())
            .collect::<Vec<_>>();

        match sorted.len() {
            0 => {
                return Self {
                    center: 0.0,
                    scale: 0.0,
                };
            }
            1 => {
                return Self {
                    center: sorted[0],
                    scale: 0.0,
                };
            }
            _ => {}
        }

        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let center = median_of_sorted(&sorted);

        // Reuse the buffer as the absolute-deviations slice, then re-sort for its
        // own median (the MAD).
        for value in sorted.iter_mut() {
            *value = (*value - center).abs();
        }
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let mad = median_of_sorted(&sorted);

        Self {
            center,
            scale: mad * MAD_TO_SIGMA,
        }
    }

    /// The dispersion the robust score divides by, raised to the configured floors
    /// — identical floor semantics to [`BaselineStats::effective_stddev`]: the max
    /// of the raw MAD-scale, an absolute floor (`min_std_floor`, metric units), and
    /// a relative coefficient-of-variation floor (`min_cv * |center|`). A window
    /// whose MAD is `0` (a pinned/discrete metric) therefore floors to a safe scale
    /// instead of dividing by zero.
    pub fn effective_scale(&self, min_std_floor: f64, min_cv: f64) -> f64 {
        let abs_floor = if min_std_floor.is_finite() && min_std_floor > 0.0 {
            min_std_floor
        } else {
            0.0
        };
        let cv_floor = if min_cv.is_finite() && min_cv > 0.0 {
            min_cv * self.center.abs()
        } else {
            0.0
        };
        self.scale.max(abs_floor).max(cv_floor)
    }
}

/// Median of an already-sorted (ascending) non-empty slice: the middle value for
/// an odd length, the mean of the two middle values for an even length.
fn median_of_sorted(sorted: &[f64]) -> f64 {
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
    let values = values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .collect::<Vec<_>>();

    match values.as_slice() {
        [] => BaselineStats {
            mean: 0.0,
            stddev: 0.0,
        },
        [value] => BaselineStats {
            mean: *value,
            stddev: 0.0,
        },
        values => {
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
    }
}

fn near_zero_stddev_floor(mean: f64) -> f64 {
    let mean_abs = mean.abs();

    if mean_abs <= f64::EPSILON {
        NEAR_ZERO_STDDEV_ABS_FLOOR
    } else {
        (mean_abs * NEAR_ZERO_STDDEV_REL_FLOOR).max(f64::EPSILON)
    }
}

fn effective_scoring_stddev(stats: BaselineStats, min_std_floor: f64, min_cv: f64) -> f64 {
    let configured = stats.effective_stddev(min_std_floor, min_cv);
    let near_zero_floor = near_zero_stddev_floor(stats.mean);

    if configured < near_zero_floor {
        near_zero_floor
    } else {
        configured
    }
}

pub fn effective_scoring_scale(stats: RobustStats, min_std_floor: f64, min_cv: f64) -> f64 {
    let configured = stats.effective_scale(min_std_floor, min_cv);
    let near_zero_floor = near_zero_stddev_floor(stats.center);

    if configured < near_zero_floor {
        near_zero_floor
    } else {
        configured
    }
}

/// The shared breach-score core: the (absolute) standardized deviation of
/// `sample_value` from `center` over an already-floored `effective_scale`. When
/// the floored dispersion is zero/non-finite (a truly flat baseline) it falls back
/// to a magnitude-aware denominator so a tiny wiggle does not breach while a large
/// excursion still ranks higher and clears `threshold`. Both the mean/std
/// [`z_score`] and the robust median/MAD [`robust_score`] reduce to this, so they
/// share identical zero-dispersion and sign/threshold semantics.
fn standardized_deviation(
    sample_value: f64,
    center: f64,
    effective_scale: f64,
    threshold: f64,
) -> f64 {
    if effective_scale <= 0.0 || !effective_scale.is_finite() {
        let deviation = (sample_value - center).abs();
        if deviation <= f64::EPSILON {
            0.0
        } else {
            let floor = center.abs().max(1.0) * f64::EPSILON.sqrt();
            let magnitude = (deviation / floor).max(0.0);
            (threshold + 1.0) + magnitude.ln_1p()
        }
    } else {
        ((sample_value - center) / effective_scale).abs()
    }
}

/// The breach score for `sample_value` against a baseline. Returns the absolute
/// z-score in the normal case; for a zero/near-zero-variance baseline it divides
/// by a magnitude-aware denominator so tiny floor-less counter-rate wiggles do
/// not breach while larger excursions still rank higher and clear `threshold`.
///
/// `min_std_floor` / `min_cv` raise the effective dispersion before dividing
/// (see [`BaselineStats::effective_stddev`]); pass `0.0` for both to recover the
/// prior pure-stddev behavior. When the floored dispersion is positive it is used
/// directly — a near-constant series with a *tiny but nonzero* stddev no longer
/// produces a huge z-score from a trivial wiggle (the live disk-1.36% false-fire).
pub fn z_score(
    sample_value: f64,
    stats: BaselineStats,
    threshold: f64,
    min_std_floor: f64,
    min_cv: f64,
) -> f64 {
    let effective_stddev = effective_scoring_stddev(stats, min_std_floor, min_cv);
    standardized_deviation(sample_value, stats.mean, effective_stddev, threshold)
}

/// The robust (median/MAD, Hampel) breach score for `sample_value`: the absolute
/// deviation `|sample_value - center| / scale` where `center` is the window median
/// and `scale` is `MAD * 1.4826`, raised to the dispersion floors first.
///
/// This is the edge detector's primary dispersion score. Its sign/threshold
/// semantics are identical to [`z_score`] (an absolute standardized deviation,
/// breaching at `>= threshold`), but it does not self-mask: a single large spike
/// in the window cannot inflate the median/MAD baseline the way it inflates a
/// mean/std baseline. `min_std_floor` / `min_cv` raise the effective scale before
/// dividing (so a pinned/discrete window with `MAD = 0` floors to a safe
/// denominator); pass `0.0` for both to use the bare robust scale.
pub fn robust_score(
    sample_value: f64,
    stats: RobustStats,
    threshold: f64,
    min_std_floor: f64,
    min_cv: f64,
) -> f64 {
    let effective_scale = effective_scoring_scale(stats, min_std_floor, min_cv);
    standardized_deviation(sample_value, stats.center, effective_scale, threshold)
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

        let small = z_score(101.0, stats, threshold, 0.0, 0.0);
        let large = z_score(10_000.0, stats, threshold, 0.0, 0.0);

        assert!(
            small < threshold,
            "a one-unit wiggle on a flat baseline must not breach"
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
    fn near_zero_stddev_uses_magnitude_floor() {
        let stats = BaselineStats {
            mean: 1_000.0,
            stddev: f64::EPSILON,
        };

        let small = z_score(1_001.0, stats, 3.0, 0.0, 0.0);
        let large = z_score(1_500.0, stats, 3.0, 0.0, 0.0);

        assert!(
            small < 3.0,
            "near-zero stddev must not amplify a tiny wiggle into score {small}"
        );
        assert!(large >= 3.0, "large move must still breach, score {large}");
    }

    #[test]
    fn near_zero_stddev_small_rate_excursion_still_breaches() {
        let stats = BaselineStats {
            mean: 0.05,
            stddev: f64::EPSILON,
        };

        let score = z_score(0.5, stats, 3.0, 0.0, 0.0);

        assert!(
            score >= 3.0,
            "a 10x low-magnitude rate excursion must breach, score {score}"
        );
    }

    #[test]
    fn sample_stats_is_defined_for_empty_and_singleton_windows() {
        let empty = sample_stats(&[]);
        assert_eq!(empty.mean, 0.0);
        assert_eq!(empty.stddev, 0.0);

        let singleton = sample_stats(&[42.0]);
        assert_eq!(singleton.mean, 42.0);
        assert_eq!(singleton.stddev, 0.0);
        assert!(singleton.mean.is_finite() && singleton.stddev.is_finite());
    }

    #[test]
    fn sample_stats_ignores_non_finite_values() {
        let stats = sample_stats(&[10.0, f64::NAN, 12.0, f64::INFINITY]);

        assert_eq!(stats.mean, 11.0);
        assert!((stats.stddev - std::f64::consts::SQRT_2).abs() < 1e-12);
    }

    #[test]
    fn near_constant_wiggle_does_not_breach_without_explicit_floor() {
        // The live false-fire: disk used_percent hovering at ~1.36% with ~0.01
        // jitter has a tiny *nonzero* stddev. The built-in near-zero dispersion
        // guard now collapses a 0.1-point bump even when no explicit per-series
        // floor is configured; an explicit floor remains at least as safe.
        let stats = BaselineStats {
            mean: 1.36,
            stddev: 0.012,
        };
        let guarded = z_score(1.46, stats, 3.0, 0.0, 0.0);
        let explicit_floor = z_score(1.46, stats, 3.0, 1.0, 0.05);

        assert!(guarded < 3.0, "benign wiggle must not breach: {guarded}");
        assert!(
            explicit_floor < 1.0,
            "explicitly floored z {explicit_floor} must also stay tiny"
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

    #[test]
    fn robust_stats_median_and_mad_scale() {
        // 50,51,52,53,54 repeating -> median 52; abs devs {2,1,0,1,2} -> MAD 1;
        // scale = 1 * 1.4826.
        let window: Vec<f64> = (0..40).map(|i| 50.0 + (i % 5) as f64).collect();
        let stats = RobustStats::from_values(&window);
        assert!(
            (stats.center - 52.0).abs() < 1e-9,
            "center {}",
            stats.center
        );
        assert!(
            (stats.scale - MAD_TO_SIGMA).abs() < 1e-9,
            "scale {}",
            stats.scale
        );
    }

    #[test]
    fn robust_stats_empty_and_singleton_are_defined() {
        let empty = RobustStats::from_values(&[]);
        assert_eq!(empty.center, 0.0);
        assert_eq!(empty.scale, 0.0);

        let singleton = RobustStats::from_values(&[42.0]);
        assert_eq!(singleton.center, 42.0);
        assert_eq!(singleton.scale, 0.0);
    }

    #[test]
    fn robust_stats_ignores_non_finite_values() {
        let stats = RobustStats::from_values(&[10.0, f64::NAN, 12.0, f64::INFINITY, 11.0]);
        // Finite values {10,11,12} -> median 11, abs devs {1,0,1} -> MAD 1.
        assert!((stats.center - 11.0).abs() < 1e-12);
        assert!((stats.scale - MAD_TO_SIGMA).abs() < 1e-12);
    }

    #[test]
    fn robust_score_breaches_a_large_excursion_and_not_a_wiggle() {
        let window: Vec<f64> = (0..40)
            .map(|i| 100.0 + if i % 2 == 0 { 0.5 } else { -0.5 })
            .collect();
        let stats = RobustStats::from_values(&window);
        let threshold = 3.0;

        let wiggle = robust_score(100.6, stats, threshold, 0.0, 0.0);
        let spike = robust_score(1_000.0, stats, threshold, 0.0, 0.0);
        assert!(
            wiggle < threshold,
            "a small wiggle must not breach ({wiggle})"
        );
        assert!(spike >= threshold, "a large spike must breach ({spike})");
        assert!(spike > wiggle);
    }

    #[test]
    fn robust_score_pinned_window_floors_instead_of_dividing_by_zero() {
        // A discrete/pinned metric: >50% identical -> MAD = 0 -> scale = 0. The
        // near-zero magnitude-aware fallback must keep a tiny wiggle benign while a
        // large move still breaches, never producing NaN/inf.
        let window = vec![100.0; 40];
        let stats = RobustStats::from_values(&window);
        assert_eq!(stats.scale, 0.0, "a pinned window has zero MAD");

        let no_move = robust_score(100.0, stats, 3.0, 0.0, 0.0);
        let small = robust_score(101.0, stats, 3.0, 0.0, 0.0);
        let large = robust_score(10_000.0, stats, 3.0, 0.0, 0.0);
        assert_eq!(no_move, 0.0);
        assert!(
            small < 3.0,
            "a one-unit wiggle on a pinned baseline must not breach"
        );
        assert!(
            large >= 3.0 && large.is_finite(),
            "a large move must still breach"
        );
        assert!(large > small);
    }

    #[test]
    fn robust_score_floors_apply_to_the_mad_scale() {
        // Near-constant ~50 with sub-0.05 jitter: tiny nonzero MAD. The absolute /
        // CV floors lift the denominator exactly as they do for mean/std, so a 0.1
        // bump is not a huge score, while a real spike still breaches.
        let window: Vec<f64> = (0..40).map(|i| 50.0 + 0.02 * ((i % 2) as f64)).collect();
        let stats = RobustStats::from_values(&window);

        let floored = robust_score(50.1, stats, 3.0, 1.0, 0.05);
        let spike = robust_score(250.0, stats, 3.0, 1.0, 0.05);
        assert!(
            floored < 1.0,
            "cv/abs-floored robust score {floored} must be small"
        );
        assert!(
            spike >= 3.0,
            "a real spike {spike} must still breach despite the floor"
        );
    }

    #[test]
    fn robust_score_does_not_self_mask_a_second_spike() {
        // The Hampel property the spec calls for: a window already containing a
        // large sustained spike must NOT have its baseline poisoned so that a second
        // spike of similar magnitude is hidden. Compare mean/std vs robust on a
        // clean window plus a window polluted by a first spike.
        let clean: Vec<f64> = (0..40).map(|i| 50.0 + (i % 3) as f64).collect();
        let mut polluted = clean.clone();
        for v in polluted.iter_mut().take(8) {
            *v = 400.0; // a big first spike occupies part of the window
        }

        let second_spike = 120.0; // the would-be-masked second spike
        let z_clean = z_score(second_spike, sample_stats(&clean), 3.0, 0.0, 0.0);
        let z_polluted = z_score(second_spike, sample_stats(&polluted), 3.0, 0.0, 0.0);
        let r_polluted = robust_score(
            second_spike,
            RobustStats::from_values(&polluted),
            3.0,
            0.0,
            0.0,
        );

        // mean/std self-masks: the first spike inflates the std so the second spike
        // no longer breaches (this is the failure mode the spec targets).
        assert!(
            z_clean >= 3.0,
            "premise: the second spike breaches a clean mean/std baseline"
        );
        assert!(
            z_polluted < 3.0,
            "premise: mean/std self-masks the second spike (z={z_polluted})"
        );
        // robust median/MAD still flags it: the first spike (<50% of the window)
        // cannot move the median/MAD enough to hide it.
        assert!(
            r_polluted >= 3.0,
            "robust median/MAD must still breach on the second spike (score {r_polluted})"
        );
    }
}
