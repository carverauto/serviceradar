use crate::DEFAULT_N_SIGMA;
use rustler::NifMap;

#[derive(Clone, Copy, Debug)]
pub(crate) struct BaselineStats {
    pub(crate) mean: f64,
    pub(crate) stddev: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, NifMap)]
pub(crate) struct WelfordAcc {
    pub(crate) count: usize,
    pub(crate) mean: f64,
    pub(crate) m2: f64,
}

impl WelfordAcc {
    pub(crate) fn from_values(values: &[f64]) -> Self {
        values
            .iter()
            .copied()
            .fold(Self::default(), |mut acc, value| {
                acc.add(value);
                acc
            })
    }

    pub(crate) fn add(&mut self, value: f64) {
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

    pub(crate) fn remove(&mut self, value: f64) {
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

        // Fix (finding 2): a would-be-negative m2 used to be silently clamped to
        // 0.0, which hides genuine numerical drift (e.g. from large-counter
        // catastrophic cancellation) behind a fabricated zero-variance baseline.
        // Tiny negatives within rounding tolerance are still benign and clamped;
        // anything larger marks the acc invalid (NAN m2) so `valid_for_count` /
        // `stats` fail and the caller rebuilds from the retained `window_tail`,
        // which is always available and cheap to recompute.
        if self.m2 < 0.0 {
            // Permit rounding-scale negatives proportional to the magnitudes
            // involved; otherwise force a recompute via an invalid acc.
            let drift_tolerance = f64::EPSILON
                * (self.m2.abs().max(old_mean.abs()).max(value.abs()).max(1.0))
                * old_count;
            if self.m2 >= -drift_tolerance {
                self.m2 = 0.0;
            } else {
                // Drift exceeds rounding tolerance: invalidate the acc (NAN m2)
                // rather than fabricate a zero. `valid_for_count`/`stats` will now
                // fail, so callers rebuild from the retained `window_tail`. We use
                // an invalid-acc signal instead of `debug_assert!` because this is
                // an expected, recoverable condition under sustained drift, not a
                // programming bug — it must degrade gracefully in release builds.
                self.m2 = f64::NAN;
            }
        }
    }

    pub(crate) fn valid_for_count(self, count: usize) -> bool {
        self.count == count
            && self.mean.is_finite()
            && self.m2.is_finite()
            && self.m2 >= 0.0
            && (count != 0 || (self.mean == 0.0 && self.m2 == 0.0))
    }

    pub(crate) fn stats(self) -> Option<BaselineStats> {
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

pub(crate) fn sample_stats(values: &[f64]) -> BaselineStats {
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

pub(crate) fn z_score(sample_value: f64, stats: BaselineStats, threshold: f64) -> f64 {
    if stats.stddev <= f64::EPSILON {
        let deviation = (sample_value - stats.mean).abs();
        if deviation <= f64::EPSILON {
            0.0
        } else {
            // Fix (finding 3): a zero-variance baseline (idle / constant counters)
            // used to collapse every breach to a constant `threshold + 1.0`,
            // flattening downstream ranking so a 1-unit blip and a 10000x spike
            // looked identical. There is no true standard deviation here, so we
            // synthesize a magnitude-aware score: it always clears `threshold`
            // (the breach DECISION is unchanged — any deviation from a flat
            // baseline still breaches) but grows with the relative deviation so
            // larger excursions rank above smaller ones. We scale the deviation
            // against a small floor derived from the baseline magnitude (so the
            // ratio is unit-relative and well-defined when mean == 0.0).
            let floor = stats.mean.abs().max(1.0) * f64::EPSILON.sqrt();
            let magnitude = (deviation / floor).max(0.0);
            // Map [breach .. unbounded] onto [threshold + 1.0 .. ): keep the
            // historical floor of `threshold + 1.0` for the smallest breach and
            // add a saturating-free, monotonically increasing magnitude term.
            (threshold + 1.0) + magnitude.ln_1p()
        }
    } else {
        ((sample_value - stats.mean) / stats.stddev).abs()
    }
}

pub(crate) fn clean_threshold(threshold: f64) -> f64 {
    if threshold.is_finite() && threshold > 0.0 {
        threshold
    } else {
        DEFAULT_N_SIGMA
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Finding 3: a zero-variance baseline must still distinguish a small from a
    // large deviation so downstream ranking stays meaningful.
    #[test]
    fn zero_variance_score_is_magnitude_aware() {
        let stats = BaselineStats {
            mean: 100.0,
            stddev: 0.0,
        };
        let threshold = 3.0;

        let small = z_score(101.0, stats, threshold);
        let large = z_score(10_000.0, stats, threshold);

        // Breach DECISION is unchanged: any deviation from a flat baseline breaches.
        assert!(small >= threshold, "small deviation must still breach");
        assert!(large >= threshold, "large deviation must still breach");

        // Ranking is now meaningful: the larger excursion outscores the small one,
        // where previously both collapsed to a constant `threshold + 1.0`.
        assert!(
            large > small,
            "large deviation ({large}) must outrank small deviation ({small})"
        );

        // The historical floor (threshold + 1.0) is preserved as the minimum
        // breach score for the smallest possible deviation.
        assert!(small >= threshold + 1.0);
    }

    // Finding 3: an exactly-on-baseline sample against zero variance is clean.
    #[test]
    fn zero_variance_no_deviation_scores_zero() {
        let stats = BaselineStats {
            mean: 42.0,
            stddev: 0.0,
        };
        assert_eq!(z_score(42.0, stats, 3.0), 0.0);
    }

    // Finding 3: zero-variance ranking must also work for a zero-mean baseline
    // (idle counters sitting at 0) where the magnitude floor cannot divide by mean.
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

    // Finding 2: a benign rounding-scale negative m2 is still tolerated (clamped
    // to a valid zero-variance acc), so normal float drift does not trigger spurious
    // recomputes.
    #[test]
    fn remove_tolerates_rounding_scale_negative_m2() {
        // Constant values => true variance is exactly zero; incremental remove may
        // leave a tiny negative m2 from rounding, which must clamp to a VALID acc.
        let mut acc = WelfordAcc::from_values(&[5.0, 5.0, 5.0, 5.0]);
        acc.remove(5.0);
        assert!(
            acc.m2.is_finite(),
            "benign drift must not invalidate the acc"
        );
        assert!(acc.valid_for_count(acc.count));
    }

    // Finding 2: a would-be-negative m2 beyond rounding tolerance must invalidate
    // the acc (NAN m2) so `valid_for_count`/`stats` fail and the caller recomputes,
    // instead of silently clamping to a fabricated zero-variance baseline.
    #[test]
    fn remove_large_negative_m2_forces_recompute() {
        let mut acc = WelfordAcc::from_values(&[1.0, 2.0, 3.0, 4.0, 5.0]);
        // Corrupt m2 to a clearly-wrong small value so the next remove drives it
        // sharply negative, simulating accumulated catastrophic-cancellation drift.
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
}
