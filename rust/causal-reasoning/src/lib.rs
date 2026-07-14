//! Generic reasoning engine.
//!
//! Phase 0 fills two things only: the CSM SPRT step (the single place an `Uncertain` is materialized
//! and sampled, from a deterministic [`ConfidenceSummary`]) and the per-tick global-sample-cache
//! discipline. The kill-chain `CausaloidGraph`, CSM registration, correction loop, and counterfactual
//! harness are added by `add-causal-security-detections` and later milestones. This crate stays generic
//! over `V: Verdict`. (OpenSpec `add-causal-security-foundation`.)
#![forbid(unsafe_code)]

pub mod sprt;

pub use sprt::{SprtParams, clear_sample_cache_at_tick_barrier, sprt_fires};
