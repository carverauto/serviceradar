//! Verdict emitter — publishes causal verdicts onto
//! `signals.causal.predictions.{device_uid|incident_id}`.
//!
//! TODO(1.6): publish over NATS JetStream with DETERMINISTIC prediction ids
//! (stable across restarts for the same verdict). The existing `CausalSignals`
//! processor + `pipeline.ex` already route the `signals.causal.*` prefix into
//! `ocsf_events`, so no new inbound plumbing is needed — verdicts re-enter
//! `StatefulAlertEngine.evaluate_events/1` (the automation loop) and drive the
//! God-View 4-bucket render.

use crate::error::Result;
use crate::reasoner::Verdict;

/// Publishes verdicts to the prediction subject.
#[derive(Default)]
pub struct Emitter {
    // TODO(1.6): NATS JetStream handle + subject config.
}

impl Emitter {
    /// Construct an emitter. TODO(1.6): connect to NATS.
    pub fn new() -> Self {
        Self::default()
    }

    /// Emit a batch of verdicts. TODO(1.6): one message per verdict with a
    /// deterministic prediction id; idempotent re-emit.
    pub async fn emit(&self, verdicts: &[Verdict]) -> Result<()> {
        let _ = verdicts;
        Ok(())
    }
}
