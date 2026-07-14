//! Layer 1 — data integration. The only crate that (in later milestones) touches CNPG / NATS / SRQL.
//!
//! Phase 0 fills the **central** confidence construction: an edge/central detector emits a robust
//! z-score (or a near-binary hit), and L1 turns it into a deterministic [`Observation`] via the
//! per-domain calibration in `causal-config`. The live `signals.state.<table>` / SRQL / JetStream
//! backends are feature-gated and land later; this milestone provides the [`ObservationSource`] seam and
//! an in-memory source for tests. (OpenSpec `add-causal-security-foundation`.)
#![forbid(unsafe_code)]

use serviceradar_causal_config::{Calibration, Quality};
use serviceradar_causal_model::{
    ConfidenceSummary, Domain, DomainFeatures, EntityKey, Observation, Timestamp,
};
use serviceradar_causal_ports::ObservationSource;
use uuid::Uuid;

/// A raw signal as it arrives from an edge or central detector, before calibration.
#[derive(Clone, Debug)]
pub enum RawSignal {
    /// A continuous anomaly score (robust z-score) for a continuous-domain series.
    Score { z: f64, quality: Quality },
    /// A near-binary hit (IOC/CIDR match, BGP new-origin, auth first-seen).
    Hit,
}

/// Construct a calibrated [`Observation`], or `None` when the signal produces no observation
/// (a continuous score fed to a near-binary domain, or a near-binary miss handled upstream).
///
/// This is the central confidence construction: the edge emits a z-score / severity, NOT an
/// `Uncertain`; L1 builds the deterministic [`ConfidenceSummary`] here.
pub fn build_observation(
    entity: EntityKey,
    domain: Domain,
    signal: RawSignal,
    ocsf_event_id: Uuid,
    observed_at: Timestamp,
) -> Option<Observation> {
    let cal = Calibration::for_domain(domain);
    let (confidence, features): (ConfidenceSummary, DomainFeatures) = match signal {
        RawSignal::Score { z, quality } => (
            cal.score_to_confidence(z, quality)?,
            DomainFeatures::Score { z },
        ),
        RawSignal::Hit => (cal.hit()?, DomainFeatures::Hit),
    };
    Some(Observation {
        entity,
        domain,
        confidence,
        features,
        ocsf_event_id,
        observed_at,
    })
}

/// An in-memory [`ObservationSource`] for tests and local harnesses. The live backends
/// (`signals.state.<table>`, SRQL snapshots) implement the same trait behind the `nats`/`srql`
/// features in later work.
#[derive(Clone, Debug, Default)]
pub struct InMemorySource {
    observations: Vec<Observation>,
}

impl InMemorySource {
    pub fn new(observations: Vec<Observation>) -> Self {
        Self { observations }
    }
}

impl ObservationSource for InMemorySource {
    fn stream(&self) -> Box<dyn Iterator<Item = Observation> + '_> {
        Box::new(self.observations.iter().cloned())
    }

    fn snapshot(&self, entity: &EntityKey) -> Vec<Observation> {
        self.observations
            .iter()
            .filter(|o| &o.entity == entity)
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn continuous_score_builds_observation() {
        let obs = build_observation(
            EntityKey::new("sr:device:host-a"),
            Domain::Flow,
            RawSignal::Score {
                z: 8.0,
                quality: Quality {
                    confirmed: true,
                    ..Default::default()
                },
            },
            Uuid::from_u128(1),
            42,
        )
        .expect("continuous score -> observation");
        assert!(obs.confidence.mean > 0.85);
        assert!(matches!(obs.features, DomainFeatures::Score { .. }));
    }

    #[test]
    fn near_binary_hit_builds_high_confidence_observation() {
        let obs = build_observation(
            EntityKey::new("sr:device:host-a"),
            Domain::ThreatIntel,
            RawSignal::Hit,
            Uuid::from_u128(2),
            42,
        )
        .expect("ioc hit -> observation");
        assert!(obs.confidence.mean > 0.9 && obs.confidence.variance < 0.05);
        assert!(matches!(obs.features, DomainFeatures::Hit));
    }

    #[test]
    fn wrong_family_yields_no_observation() {
        // A continuous score has no meaning for a near-binary domain.
        assert!(
            build_observation(
                EntityKey::new("sr:x"),
                Domain::ThreatIntel,
                RawSignal::Score {
                    z: 5.0,
                    quality: Quality::default()
                },
                Uuid::from_u128(3),
                0,
            )
            .is_none()
        );
    }

    #[test]
    fn in_memory_source_snapshots_by_entity() {
        let e = EntityKey::new("sr:device:host-a");
        let obs = build_observation(
            e.clone(),
            Domain::Dns,
            RawSignal::Score {
                z: 6.0,
                quality: Quality {
                    confirmed: true,
                    ..Default::default()
                },
            },
            Uuid::from_u128(4),
            0,
        )
        .unwrap();
        let src = InMemorySource::new(vec![obs]);
        assert_eq!(src.snapshot(&e).len(), 1);
        assert_eq!(src.snapshot(&EntityKey::new("sr:other")).len(), 0);
        assert_eq!(src.stream().count(), 1);
    }
}
