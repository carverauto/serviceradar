//! Causal security engine — shared vocabulary (Phase 0, OpenSpec `add-causal-security-foundation`).
//!
//! This is isolation tier 0: the entity/domain vocabulary, the deterministic [`ConfidenceSummary`],
//! the [`SecVerdict`] lawful [`Verdict`] lattice, and the [`Observation`] model the reasoning layer
//! consumes. It carries NO IO and depends only on `deep_causality_algebra` (for the `Verdict` trait).
//!
//! Confidence flows as a deterministic `(mean, variance)` summary, never a live `Uncertain`:
//! DeepCausality's `impl Verdict for Uncertain<f64>` is idempotent only for shared `Arc` leaves and
//! inflates at reconvergence, so the verdict carries the summary and `join` is a pure comparison. The
//! single `Uncertain` is materialized only at the CSM SPRT (see `serviceradar-causal-reasoning`).
#![forbid(unsafe_code)]

mod confidence;
mod entity;
mod observation;
mod verdict;

pub use confidence::{ConfidenceSummary, combine_independent, conf_glb, conf_lub};
pub use entity::{Domain, DomainFeatures, EntityKey};
pub use observation::Observation;
pub use verdict::{EvidenceCluster, EvidenceRef, SecVerdict, Severity, Stage, Timestamp};

// Re-export the lattice trait so consumers can call `.join()`/`.meet()` without importing the DC crate.
pub use deep_causality_algebra::Verdict;
