//! Mitigation authority — the config-driven `causal_mitigation_policies` engine (shadow/enforce,
//! default-deny, blast-radius gate) and the northbound action descriptors. SCAFFOLD ONLY in Phase 0;
//! authored by `add-causal-mitigation`. (OpenSpec `add-causal-security-foundation`.)
#![forbid(unsafe_code)]

// The decision surface this crate will implement.
pub use serviceradar_causal_ports::{ActionExecutor, Authority, MitigationPolicy};
