//! The reasoner — a DeepCausality `CausaloidGraph` evaluated over an
//! `ultragraph` `CsmGraph`.
//!
//! TODO(1.3): build the graph layer on `ultragraph` 0.9 (`CsmGraph` CSR;
//! `freeze()` before each tick, `unfreeze()` only on real topology change) and
//! wrap it in a DeepCausality `CausaloidGraph`.
//! TODO(1.4): implement causaloids C1–C13. Six are direct `ultragraph` 0.9
//! library calls — `articulation_points`/`bridges` (C5/C5b), `is_reachable`
//! (C4/C7/C8), `pathway_betweenness_centrality` (C9).
//! TODO(1.5): compose per-device risk (`risk_score` + `pkg_*` scalars) into
//! C5/C7/C10 as numeric observations.

use crate::domain_model::Context;
use crate::error::Result;

/// Verdict classification — maps cleanly onto the God-View 4-bucket render
/// (`root_cause` / `affected` / `healthy` / `unknown`, `GodViewSnapshot`
/// schema_version 2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Classification {
    /// Identified root cause.
    RootCause,
    /// Predicted/observed to be affected by a root cause.
    Affected,
    /// Healthy.
    Healthy,
    /// State cannot be determined (e.g. unobservable).
    Unknown,
}

/// A causal verdict for a single entity.
#[derive(Debug, Clone)]
pub struct Verdict {
    /// Canonical `sr:`-prefixed entity id the verdict applies to.
    pub entity_id: String,
    /// The causal classification.
    pub classification: Classification,
    /// Human-readable explanation (drives the God-View explainability surface).
    pub reason: String,
}

/// The DeepCausality reasoner.
#[derive(Default)]
pub struct Reasoner {
    // TODO(1.3): CausaloidGraph + the frozen ultragraph CsmGraph.
}

impl Reasoner {
    /// Construct a reasoner. TODO(1.3): build the CausaloidGraph.
    pub fn new() -> Self {
        Self::default()
    }

    /// Run one reasoning tick over the hydrated context: freeze the graph,
    /// evaluate causaloids C1–C13, and collect verdicts.
    ///
    /// TODO(1.3/1.4/1.5): real causaloid evaluation + risk composition.
    pub fn evaluate(&self, ctx: &Context) -> Result<Vec<Verdict>> {
        let _ = ctx;
        Ok(Vec::new())
    }
}
