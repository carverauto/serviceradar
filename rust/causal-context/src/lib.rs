//! Layer 2 — the DeepCausality Context world model (asset criticality, IOC Symboids, topology
//! reachability). SCAFFOLD ONLY in Phase 0; the Contextoid hypergraph and the `ContextStore`
//! implementation are filled by `add-causal-security-detections`. (OpenSpec `add-causal-security-foundation`.)
#![forbid(unsafe_code)]

// Re-exported so downstream crates can name the seam this crate will implement.
pub use serviceradar_causal_ports::ContextStore;
