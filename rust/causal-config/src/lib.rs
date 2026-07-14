//! Per-domain static calibration: an edge/central score becomes a deterministic `ConfidenceSummary`.
//!
//! This is the seam the analyst-label loop (`add-causal-detection-feedback`) later re-fits. Two families:
//! - **continuous** domains map a robust z-score through a logistic anchored to reuse the deployed
//!   `4.0`/`8.0` z-score severity cutpoints (numeric parity with `anomaly-addon`'s severity bands);
//! - **near-binary** domains map a hit directly to high-mean/low-variance (a z-score is meaningless for
//!   a Bernoulli signal); a miss produces no Observation.
//!
//! Phase 0 (OpenSpec `add-causal-security-foundation`).
#![forbid(unsafe_code)]

use serviceradar_causal_model::{ConfidenceSummary, Domain};

/// Calibration family for a domain.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Calibration {
    /// Continuous: `mean = 1 / (1 + exp(-k * (z - z0)))`, anchored at the `4.0`/`8.0` cutpoints.
    Logistic { k: f64, z0: f64, base_variance: f64 },
    /// Near-binary: a hit maps to `(hit_mean, hit_variance)`; a miss yields no Observation.
    Bernoulli { hit_mean: f64, hit_variance: f64 },
}

/// Low-information signals that widen the constructed variance.
#[derive(Clone, Copy, Debug, Default)]
pub struct Quality {
    /// The edge/central detector confirmed the anomaly (not merely pending).
    pub confirmed: bool,
    /// The baseline had fewer than the minimum samples.
    pub thin_baseline: bool,
    /// Only the zero-dispersion magnitude fallback fired (a low-information score).
    pub magnitude_fallback: bool,
}

impl Calibration {
    /// Default per-domain calibration. The logistic `k = 0.5`, `z0 = 3.0` gives `z=3 -> 0.50`,
    /// `z=4 -> ~0.62`, `z=8 -> ~0.92`, matching the shipped Low/Medium/High severity bands.
    pub fn for_domain(domain: Domain) -> Self {
        match domain {
            // Inherently binary: a threat-intel IOC/CIDR hit is near-certain, not a z-score.
            Domain::ThreatIntel => Calibration::Bernoulli {
                hit_mean: 0.92,
                hit_variance: 0.01,
            },
            // Continuous z-score families.
            Domain::Dns
            | Domain::Flow
            | Domain::Auth
            | Domain::Host
            | Domain::Routing
            | Domain::Vuln
            | Domain::Scan => Calibration::Logistic {
                k: 0.5,
                z0: 3.0,
                base_variance: 0.05,
            },
        }
    }

    /// Map a continuous z-score to a `ConfidenceSummary`. Returns `None` for a `Bernoulli` family
    /// (use [`Calibration::hit`] instead).
    pub fn score_to_confidence(&self, z: f64, q: Quality) -> Option<ConfidenceSummary> {
        match *self {
            Calibration::Logistic {
                k,
                z0,
                base_variance,
            } => {
                let mean = 1.0 / (1.0 + (-k * (z - z0)).exp());
                let mut variance = base_variance;
                if !q.confirmed {
                    variance *= 3.0;
                }
                if q.thin_baseline {
                    variance *= 2.0;
                }
                if q.magnitude_fallback {
                    variance *= 2.0;
                }
                Some(ConfidenceSummary::new(mean, variance))
            }
            Calibration::Bernoulli { .. } => None,
        }
    }

    /// The confidence for a near-binary hit. Returns `None` for a `Logistic` (continuous) family.
    pub fn hit(&self) -> Option<ConfidenceSummary> {
        match *self {
            Calibration::Bernoulli {
                hit_mean,
                hit_variance,
            } => Some(ConfidenceSummary::new(hit_mean, hit_variance)),
            Calibration::Logistic { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn logistic_anchors_at_deployed_cutpoints() {
        let cal = Calibration::for_domain(Domain::Flow);
        let q = Quality {
            confirmed: true,
            ..Default::default()
        };
        let at = |z: f64| cal.score_to_confidence(z, q).unwrap().mean;
        assert!((at(3.0) - 0.5).abs() < 1e-9, "z=threshold -> 0.5");
        assert!(
            (at(4.0) - 0.6).abs() < 0.05,
            "z=4 (Low/Medium cutpoint) ~ 0.6"
        );
        assert!(
            (at(8.0) - 0.9).abs() < 0.05,
            "z=8 (Medium/High cutpoint) ~ 0.9"
        );
        assert!(at(8.0) > at(4.0) && at(4.0) > at(3.0), "monotone");
    }

    #[test]
    fn low_information_widens_variance() {
        let cal = Calibration::for_domain(Domain::Dns);
        let confirmed = cal
            .score_to_confidence(
                6.0,
                Quality {
                    confirmed: true,
                    ..Default::default()
                },
            )
            .unwrap();
        let pending = cal
            .score_to_confidence(
                6.0,
                Quality {
                    confirmed: false,
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(pending.variance > confirmed.variance);
        assert_eq!(pending.mean, confirmed.mean);
    }

    #[test]
    fn near_binary_hit_is_high_mean_low_variance() {
        let cal = Calibration::for_domain(Domain::ThreatIntel);
        let hit = cal.hit().unwrap();
        assert!(hit.mean > 0.9 && hit.variance < 0.05);
        // A continuous score has no meaning for a Bernoulli family.
        assert!(cal.score_to_confidence(5.0, Quality::default()).is_none());
    }
}
