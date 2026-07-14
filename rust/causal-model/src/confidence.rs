//! The deterministic confidence summary and its closed-form combiners.
//!
//! Confidence is a `(mean, variance)` pair in `[0, 1]`, NOT a live `Uncertain`. The verdict lattice
//! combines confidence by [`conf_lub`] (max-on-mean) at reconvergence — a pure comparison with no
//! sampling. Cross-cluster fusion ([`combine_independent`]) is likewise closed-form. The full
//! `Uncertain::normal(mean, sqrt(variance))` is reconstructed only at the CSM SPRT.

use core::cmp::Ordering;

/// Deterministic confidence: a `(mean, variance)` summary with `mean` in `[0, 1]`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ConfidenceSummary {
    pub mean: f64,
    pub variance: f64,
}

impl Default for ConfidenceSummary {
    /// The join identity: zero confidence, maximally uncertain.
    fn default() -> Self {
        Self {
            mean: 0.0,
            variance: 1.0,
        }
    }
}

impl ConfidenceSummary {
    /// Construct a summary, clamping `mean` into `[0, 1]` and `variance` to non-negative.
    pub fn new(mean: f64, variance: f64) -> Self {
        Self {
            mean: mean.clamp(0.0, 1.0),
            variance: variance.max(0.0),
        }
    }

    /// Total order for the confidence chain lattice: higher `mean` is greater; on a `mean` tie the
    /// SMALLER `variance` is greater (a tighter estimate wins). `total_cmp` keeps it total even for
    /// pathological floats.
    fn cmp_key(&self, other: &Self) -> Ordering {
        match self.mean.total_cmp(&other.mean) {
            Ordering::Equal => other.variance.total_cmp(&self.variance),
            ord => ord,
        }
    }
}

/// Least-upper-bound: the summary with the greater mean (tie → smaller variance). Idempotent,
/// commutative, associative — a pure comparison, no sampling.
pub fn conf_lub(a: ConfidenceSummary, b: ConfidenceSummary) -> ConfidenceSummary {
    if a.cmp_key(&b) == Ordering::Less {
        b
    } else {
        a
    }
}

/// Greatest-lower-bound: the summary with the lesser mean (tie → larger variance).
pub fn conf_glb(a: ConfidenceSummary, b: ConfidenceSummary) -> ConfidenceSummary {
    if a.cmp_key(&b) == Ordering::Less {
        a
    } else {
        b
    }
}

/// Combine genuinely independent evidence clusters (after correlated same-session evidence has
/// already been collapsed to one cluster each). Closed-form on the summaries:
/// - mean via noisy-OR (`1 − ∏(1 − meanᵢ)`): independent corroboration raises confidence;
/// - variance via inverse-variance combination: corroboration tightens the estimate.
///
/// Provisional Phase-0 form; the exact combiner and per-domain parameters are tuned later with the
/// analyst-label calibration loop (`add-causal-detection-feedback`).
pub fn combine_independent(clusters: &[ConfidenceSummary]) -> ConfidenceSummary {
    if clusters.is_empty() {
        return ConfidenceSummary::new(0.0, 1.0);
    }
    let prod_complement: f64 = clusters.iter().map(|c| 1.0 - c.mean).product();
    let mean = 1.0 - prod_complement;
    let inv_var_sum: f64 = clusters.iter().map(|c| 1.0 / (c.variance + 1e-6)).sum();
    let variance = 1.0 / inv_var_sum;
    ConfidenceSummary::new(mean, variance)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(mean: f64, variance: f64) -> ConfidenceSummary {
        ConfidenceSummary::new(mean, variance)
    }

    #[test]
    fn lub_picks_higher_mean() {
        assert_eq!(conf_lub(c(0.3, 0.1), c(0.7, 0.2)), c(0.7, 0.2));
        assert_eq!(conf_lub(c(0.7, 0.2), c(0.3, 0.1)), c(0.7, 0.2)); // commutative
    }

    #[test]
    fn lub_tie_breaks_to_smaller_variance() {
        assert_eq!(conf_lub(c(0.5, 0.30), c(0.5, 0.10)), c(0.5, 0.10));
    }

    #[test]
    fn lub_is_idempotent() {
        let x = c(0.6, 0.2);
        assert_eq!(conf_lub(x, x), x);
    }

    #[test]
    fn lub_is_associative() {
        let (a, b, d) = (c(0.2, 0.3), c(0.9, 0.4), c(0.5, 0.1));
        assert_eq!(conf_lub(conf_lub(a, b), d), conf_lub(a, conf_lub(b, d)));
    }

    #[test]
    fn absorption_holds() {
        // conf_lub(a, conf_glb(a, b)) == a
        let (a, b) = (c(0.4, 0.2), c(0.8, 0.1));
        assert_eq!(conf_lub(a, conf_glb(a, b)), a);
        assert_eq!(conf_glb(a, conf_lub(a, b)), a);
    }

    #[test]
    fn combine_independent_raises_mean_and_tightens() {
        let fused = combine_independent(&[c(0.6, 0.2), c(0.5, 0.2)]);
        assert!(fused.mean > 0.6, "noisy-OR raises above any single mean");
        assert!(
            fused.variance < 0.2,
            "inverse-variance tightens below any single variance"
        );
        assert!(fused.mean <= 1.0);
    }

    #[test]
    fn new_clamps() {
        assert_eq!(
            c(1.7, -3.0),
            ConfidenceSummary {
                mean: 1.0,
                variance: 0.0
            }
        );
    }
}
