//! Boundary traits — the isolation seam between L1 (ingest), L2 (context), and L3 (reasoning).
//!
//! No layer depends on another's implementation, only on these traits plus `causal-model`. Re-implementing
//! them is what lets the fused in-process engine later split into networked components with no reasoning
//! change. Phase 0 (OpenSpec `add-causal-security-foundation`).
#![forbid(unsafe_code)]

use serviceradar_causal_model::{EntityKey, Observation, SecVerdict};

/// L1 → L3: a source of calibrated Observations. The only implementor (in `causal-ingest`) touches
/// CNPG / NATS / SRQL; reasoning depends on this trait, never the backend.
pub trait ObservationSource {
    /// Live delta stream (JetStream / `signals.state.<table>`).
    fn stream(&self) -> Box<dyn Iterator<Item = Observation> + '_>;
    /// On-demand snapshot for one entity (SRQL).
    fn snapshot(&self, entity: &EntityKey) -> Vec<Observation>;
}

/// L2: the DeepCausality Context world model (hydration + lifecycle). Opaque in Phase 0; the
/// hypergraph is filled by `add-causal-security-detections`.
pub trait ContextStore {
    fn hydrate(&mut self, src: &dyn ObservationSource);
    fn on_topology_change(&mut self);
}

/// L3 → output: publish a verdict (e.g. to `signals.analytics.predictions.*`).
pub trait Emitter {
    fn emit(&self, verdict: &SecVerdict) -> Result<(), EmitError>;
}

/// Failure to emit a verdict.
#[derive(Debug)]
pub struct EmitError(pub String);

/// The config-driven mitigation-authority decision (owned by `add-causal-mitigation`).
pub trait MitigationPolicy {
    fn decide(&self, verdict: &SecVerdict, blast_radius: u32) -> Authority;
}

/// Who may act on a verdict. Default-deny is `AlertOnly`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Authority {
    AutoFire,
    RequireApproval,
    AlertOnly,
    Suppress,
}

/// Executes a northbound action (owned by `add-causal-mitigation`; the action descriptors are net-new).
pub trait ActionExecutor {
    fn execute(&self, verdict: &SecVerdict) -> Result<(), ActionError>;
}

/// Failure to execute a mitigation action.
#[derive(Debug)]
pub struct ActionError(pub String);
