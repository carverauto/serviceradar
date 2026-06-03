//! Verdict emitter — publishes causal verdicts onto
//! `signals.causal.predictions.<entity>` over NATS JetStream (task 1.6).
//!
//! The existing `CausalSignals` processor + `pipeline.ex` already route the
//! `signals.causal.*` prefix into `ocsf_events`, so no new inbound plumbing is
//! needed — verdicts re-enter `StatefulAlertEngine.evaluate_events/1` (the
//! automation loop) and drive the God-View 4-bucket render. Prediction ids are
//! DETERMINISTIC so re-emitting the same verdict is idempotent (the processor
//! dedupes on `event_identity`).

use async_nats::jetstream::Context as JetStreamContext;
use chrono::Utc;
use serde_json::{json, Value};

use crate::error::{CausalEngineError, Result};
use crate::reasoner::{Classification, Verdict};

/// Root subject for emitted predictions. Per-entity tokens are appended.
const PREDICTION_SUBJECT_ROOT: &str = "signals.causal.predictions";

/// Publishes verdicts to the prediction subject via JetStream.
pub struct Emitter {
    js: JetStreamContext,
}

impl Emitter {
    /// Build an emitter over an existing JetStream context (see [`crate::nats::connect`]).
    pub fn new(js: JetStreamContext) -> Self {
        Self { js }
    }

    /// Publish a batch of verdicts, one message per verdict, awaiting each ack.
    pub async fn emit(&self, verdicts: &[Verdict]) -> Result<()> {
        for verdict in verdicts {
            let envelope = build_envelope(verdict);
            let payload = serde_json::to_vec(&envelope)
                .map_err(|e| CausalEngineError::Emit(format!("encode: {e}")))?;
            let subject = format!(
                "{PREDICTION_SUBJECT_ROOT}.{}",
                subject_token(&verdict.entity_id)
            );
            self.js
                .publish(subject, payload.into())
                .await
                .map_err(|e| CausalEngineError::Emit(format!("publish: {e}")))?
                .await
                .map_err(|e| CausalEngineError::Emit(format!("ack: {e}")))?;
        }
        Ok(())
    }
}

/// Build the OCSF-compatible causal-signal envelope for a verdict. Public for
/// unit testing; mirrors the shape the `CausalSignals` processor normalizes.
pub fn build_envelope(verdict: &Verdict) -> Value {
    let classification = classification_str(verdict.classification);
    let prediction_id = deterministic_prediction_id(verdict);
    json!({
        "schema_version": "1.0",
        "signal_type": "causal",
        // event_type maps cleanly onto the God-View 4 buckets
        // (root_cause / affected / healthy / unknown).
        "event_type": classification,
        "severity_id": 1,
        "source": {
            "subject": format!("{PREDICTION_SUBJECT_ROOT}.{}", subject_token(&verdict.entity_id)),
            "collector": "causal-engine",
            "system": "serviceradar"
        },
        "source_identity": { "entity_uid": verdict.entity_id },
        // Deterministic id => idempotent re-emit (processor dedupes on this).
        "event_identity": prediction_id,
        "event_time": Utc::now().to_rfc3339(),
        "routing_correlation": {
            "record_id": verdict.entity_id,
            "topology_keys": [verdict.entity_id]
        },
        "signal_domains": ["causal"],
        "primary_domain": "causal",
        "explainability": {
            "classification": classification,
            "reason": verdict.reason
        },
        "guardrails": {}
    })
}

/// Stable, restart-independent id for a verdict so re-emission is idempotent.
fn deterministic_prediction_id(verdict: &Verdict) -> String {
    format!(
        "pred:{}:{}",
        verdict.entity_id,
        classification_str(verdict.classification)
    )
}

/// Map a classification to its God-View bucket string.
fn classification_str(classification: Classification) -> &'static str {
    match classification {
        Classification::RootCause => "root_cause",
        Classification::Affected => "affected",
        Classification::Healthy => "healthy",
        Classification::Unknown => "unknown",
    }
}

/// Sanitize an entity id into a single NATS subject token (no `.`/space/`*`/`>`).
/// The canonical `sr:`-prefixed id keeps its `:` separators, which are subject-safe.
fn subject_token(entity_id: &str) -> String {
    entity_id.replace(['.', ' ', '*', '>'], "_")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reasoner::{Classification, Verdict};

    fn verdict() -> Verdict {
        Verdict {
            entity_id: "sr:device:abc".to_string(),
            classification: Classification::RootCause,
            reason: "gateway G unavailable; shared by N devices".to_string(),
        }
    }

    #[test]
    fn envelope_is_deterministic_and_well_formed() {
        let v = verdict();
        let a = build_envelope(&v);
        let b = build_envelope(&v);

        assert_eq!(a["event_identity"], b["event_identity"]);
        assert_eq!(a["event_identity"], "pred:sr:device:abc:root_cause");
        assert_eq!(a["signal_type"], "causal");
        assert_eq!(a["event_type"], "root_cause");
        assert_eq!(a["primary_domain"], "causal");
        assert_eq!(a["source_identity"]["entity_uid"], "sr:device:abc");
        assert_eq!(a["explainability"]["reason"], v.reason);
        assert!(serde_json::to_string(&a).is_ok());
    }

    #[test]
    fn classifications_map_to_god_view_buckets() {
        assert_eq!(classification_str(Classification::RootCause), "root_cause");
        assert_eq!(classification_str(Classification::Affected), "affected");
        assert_eq!(classification_str(Classification::Healthy), "healthy");
        assert_eq!(classification_str(Classification::Unknown), "unknown");
    }

    #[test]
    fn subject_token_sanitizes_unsafe_chars() {
        assert_eq!(subject_token("sr:device:a.b c*d>e"), "sr:device:a_b_c_d_e");
    }
}
