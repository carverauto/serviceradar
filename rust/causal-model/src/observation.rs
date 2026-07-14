//! The stable Observation model the reasoning layer consumes.

use crate::confidence::ConfidenceSummary;
use crate::entity::{Domain, DomainFeatures, EntityKey};
use crate::verdict::Timestamp;
use uuid::Uuid;

/// One calibrated, per-domain signal. This is the L1 → L3 contract: no SRQL/NATS/CNPG type leaks past
/// it. `confidence` is a deterministic [`ConfidenceSummary`] constructed by L1 calibration (see
/// `serviceradar-causal-config`), so nothing samples at ingestion.
#[derive(Clone, Debug, PartialEq)]
pub struct Observation {
    /// Canonical `sr:`-prefixed subject of the signal.
    pub entity: EntityKey,
    pub domain: Domain,
    pub confidence: ConfidenceSummary,
    pub features: DomainFeatures,
    /// Provenance back to the CNPG `ocsf_events` row (or equivalent).
    pub ocsf_event_id: Uuid,
    pub observed_at: Timestamp,
}
