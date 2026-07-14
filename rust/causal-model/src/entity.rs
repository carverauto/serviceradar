//! Entity identity and cross-domain vocabulary.

/// Canonical `sr:`-prefixed entity identity (mirrors `RuntimeGraph.canonical_runtime_id/1`). The
/// reasoning layer reuses these ids verbatim and never invents a parallel id space.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EntityKey(pub String);

impl EntityKey {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A cross-domain signal source. Each `Observation` belongs to exactly one domain. `Ord` gives
/// evidence a canonical sort key so the verdict lattice stays associative under structural equality.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Domain {
    Dns,
    Flow,
    Auth,
    Host,
    Routing,
    Vuln,
    ThreatIntel,
    Scan,
}

/// Domain-specific observation payload. Kept deliberately small in Phase 0; detection milestones
/// extend it with structured per-domain features.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum DomainFeatures {
    /// A continuous anomaly score (a robust z-score from the edge or a central detector).
    Score { z: f64 },
    /// A near-binary hit (IOC/CIDR match, BGP new-origin, auth first-seen).
    Hit,
    /// Placeholder until a domain fills in structured features.
    Opaque,
}
