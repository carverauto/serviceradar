//! Output — publish a `SecVerdict` on `signals.analytics.predictions.{device_uid|incident_id}` (via
//! `ServiceRadar.Observability.CausalPredictionSubject`), routed by the `AnalyticsSignals` processor
//! into `ocsf_events`, closing the automation loop through `StatefulAlertEngine`. SCAFFOLD ONLY in
//! Phase 0; the JetStream producer is wired in `add-causal-security-detections`.
//! (OpenSpec `add-causal-security-foundation`.)
#![forbid(unsafe_code)]

// The output seam this crate will implement.
pub use serviceradar_causal_ports::{EmitError, Emitter};
