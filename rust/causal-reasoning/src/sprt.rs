//! The single SPRT step + per-tick sample-cache discipline.
//!
//! Confidence flows through the graph as a deterministic [`ConfidenceSummary`]; the ONLY place an
//! `Uncertain` is materialized and sampled is [`sprt_fires`], called once per incident hypothesis at
//! the CSM. Because the DeepCausality sample cache is process-global, unbounded, and mints a fresh id
//! per `Uncertain` construction, the reasoning loop must call [`clear_sample_cache_at_tick_barrier`] at
//! the tick barrier so the cache is bounded per-tick scratch rather than an unbounded leak.

use deep_causality_uncertain::{Uncertain, UncertainError, with_global_cache};
use serviceradar_causal_model::ConfidenceSummary;

/// SPRT operating point. `max_samples` is bounded (≈200), not the 1000-sample default; the test is
/// sequential with early-exit at a Wald boundary, so a clear signal terminates in tens of samples.
#[derive(Clone, Copy, Debug)]
pub struct SprtParams {
    /// Value threshold: the incident fires when the confidence exceeds this.
    pub threshold: f64,
    /// Probability threshold for the hypothesis `P(confidence > threshold) > prob_threshold`
    /// (0.5 = "more likely than not", matching DeepCausality's `is_active` convention).
    pub prob_threshold: f64,
    /// SPRT confidence level.
    pub confidence: f64,
    /// SPRT indifference region half-width.
    pub epsilon: f64,
    pub max_samples: usize,
}

impl Default for SprtParams {
    fn default() -> Self {
        Self {
            threshold: 0.9,
            prob_threshold: 0.5,
            confidence: 0.95,
            epsilon: 0.05,
            max_samples: 200,
        }
    }
}

/// Reconstruct ONE `Uncertain::normal(mean, sqrt(variance))` from the fused summary and run the single
/// bounded SPRT: is `P(confidence > threshold) > prob_threshold` established at the requested
/// confidence level? This is the only sampling on the reasoning path — the value threshold is applied
/// lazily via `greater_than`, then the sequential test collapses the boolean.
pub fn sprt_fires(conf: ConfidenceSummary, params: SprtParams) -> Result<bool, UncertainError> {
    let u = Uncertain::<f64>::normal(conf.mean, conf.variance.sqrt());
    u.greater_than(params.threshold).probability_exceeds(
        params.prob_threshold,
        params.confidence,
        params.epsilon,
        params.max_samples,
    )
}

/// Clear the whole DeepCausality global sample cache. Call at the per-tick barrier — after all incident
/// evaluations for the tick complete and while no SPRT is in flight (the clear is process-wide). This
/// keeps the cache bounded to one tick's draws instead of leaking monotonically.
pub fn clear_sample_cache_at_tick_barrier() {
    with_global_cache(|cache| cache.clear());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn high_confidence_fires_low_does_not() {
        let params = SprtParams::default();
        // Tight, high-mean summary: P(x > 0.9) should be established.
        let hot = ConfidenceSummary::new(0.97, 0.0009); // sigma = 0.03
        assert!(sprt_fires(hot, params).unwrap());
        // Tight, low-mean summary: clearly below threshold.
        let cold = ConfidenceSummary::new(0.30, 0.0009);
        assert!(!sprt_fires(cold, params).unwrap());
    }

    #[test]
    fn tick_barrier_clear_is_callable() {
        // Populate the cache with a couple of evaluations, then clear at the barrier.
        let _ = sprt_fires(ConfidenceSummary::new(0.95, 0.001), SprtParams::default());
        clear_sample_cache_at_tick_barrier();
    }
}
