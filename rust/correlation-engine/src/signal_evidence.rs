//! Live prediction-signal evidence.
//!
//! Core-elx emits anomaly and capacity forecast findings on
//! `signals.analytics.predictions.*`. The fused correlation engine consumes those
//! signals as evidence by projecting each active finding into the operator-rule
//! evidence set already evaluated by C12.

use chrono::{DateTime, Utc};
use serde_json::Value;

use crate::domain_model::{Context, OperatorRule};

/// A prediction finding emitted by core-elx and usable as C12 evidence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignalEvidence {
    /// Stable finding/evidence id.
    pub rule_id: String,
    /// Canonical or best-known entity the finding applies to.
    pub entity_uid: String,
    /// Whether the finding is currently active.
    pub condition_met: bool,
    /// Human-readable explanation.
    pub description: String,
    /// Last update timestamp in Unix milliseconds.
    pub last_updated_unix_ms: i64,
}

/// Parse an anomaly or capacity forecast prediction-signal envelope.
pub fn parse_prediction_signal(envelope: &Value) -> Option<SignalEvidence> {
    if envelope.get("signal_type").and_then(|v| v.as_str())? != "prediction" {
        return None;
    }

    let event_type = envelope.get("event_type")?.as_str()?;
    if !matches!(event_type, "anomaly" | "capacity_forecast") {
        return None;
    }

    let entity_uid = first_string(&[
        envelope.pointer("/source_identity/entity_uid"),
        envelope.get("device_uid"),
        envelope.get("device_id"),
        envelope.pointer("/routing_correlation/record_id"),
    ])?;

    let evidence_id = first_string(&[
        envelope.pointer("/finding_info/group_uid"),
        envelope.pointer("/finding_info/uid"),
        envelope.pointer("/capacity_forecast/resource_key"),
        envelope.pointer("/source_identity/resource_key"),
        envelope.pointer("/source_identity/series_key"),
        envelope.pointer("/routing_correlation/record_id"),
        envelope.get("event_identity"),
        envelope.get("id"),
        envelope.get("event_id"),
    ])
    .unwrap_or_else(|| format!("{event_type}:{entity_uid}"));

    let description = first_string(&[
        envelope.get("message"),
        envelope.pointer("/explainability/reason"),
        envelope.pointer("/anomaly/reason"),
        envelope.pointer("/capacity_forecast/projected_exhaustion_at"),
    ])
    .unwrap_or_else(|| format!("{event_type} finding for {entity_uid}"));

    let status = evidence_status(envelope);

    Some(SignalEvidence {
        rule_id: format!("correlation:{event_type}:{evidence_id}"),
        entity_uid,
        condition_met: active_status(&status),
        description,
        last_updated_unix_ms: evidence_last_updated_unix_ms(envelope),
    })
}

/// Upsert signal evidence into the C12 operator-rule evidence vector.
pub fn apply_signal_evidence(ctx: &mut Context, evidence: &SignalEvidence) -> bool {
    if !evidence.condition_met {
        let before = ctx.operator_rules.len();
        ctx.operator_rules
            .retain(|existing| existing.rule_id != evidence.rule_id);
        return ctx.operator_rules.len() != before;
    }

    let rule = OperatorRule {
        rule_id: evidence.rule_id.clone(),
        entity_uid: evidence.entity_uid.clone(),
        condition_met: evidence.condition_met,
        description: evidence.description.clone(),
        last_updated_unix_ms: evidence.last_updated_unix_ms,
    };

    if let Some(existing) = ctx
        .operator_rules
        .iter_mut()
        .find(|existing| existing.rule_id == evidence.rule_id)
    {
        let changed = existing.entity_uid != rule.entity_uid
            || existing.condition_met != rule.condition_met
            || existing.description != rule.description;
        *existing = rule;
        changed
    } else {
        ctx.operator_rules.push(rule);
        true
    }
}

fn first_string(values: &[Option<&Value>]) -> Option<String> {
    values
        .iter()
        .filter_map(|value| value.and_then(Value::as_str))
        .map(str::trim)
        .find(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn evidence_status(envelope: &Value) -> String {
    first_string(&[
        envelope.get("status"),
        envelope.pointer("/anomaly/status"),
        envelope.pointer("/anomaly/state"),
        envelope.pointer("/capacity_forecast/status"),
    ])
    .unwrap_or_else(|| "open".to_string())
}

fn active_status(status: &str) -> bool {
    !matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "closed"
            | "resolved"
            | "inactive"
            | "cleared"
            | "clear"
            | "normal"
            | "ok"
            | "healthy"
            | "suppressed"
            | "skipped"
    )
}

fn evidence_last_updated_unix_ms(envelope: &Value) -> i64 {
    first_unix_nano_ms(&[
        envelope.pointer("/anomaly/observed_at_unix_nano"),
        envelope.get("observed_at_unix_nano"),
    ])
    .or_else(|| {
        first_rfc3339_unix_ms(&[
            envelope.get("timestamp"),
            envelope.pointer("/anomaly/observed_at"),
            envelope.pointer("/capacity_forecast/forecasted_at"),
        ])
    })
    .unwrap_or_else(|| Utc::now().timestamp_millis())
}

fn first_unix_nano_ms(values: &[Option<&Value>]) -> Option<i64> {
    values
        .iter()
        .filter_map(|value| value.and_then(Value::as_i64))
        .find(|value| *value >= 0)
        .map(|value| value / 1_000_000)
}

fn first_rfc3339_unix_ms(values: &[Option<&Value>]) -> Option<i64> {
    values
        .iter()
        .filter_map(|value| value.and_then(Value::as_str))
        .filter_map(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc).timestamp_millis())
        .next()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn parses_anomaly_prediction_as_signal_evidence() {
        let evidence = parse_prediction_signal(&json!({
            "signal_type": "prediction",
            "event_type": "anomaly",
            "event_id": "anomaly:e1",
            "source_identity": {"entity_uid": "sr:device:a"},
            "message": "Anomaly detected"
        }))
        .expect("evidence");

        assert_eq!(evidence.rule_id, "correlation:anomaly:anomaly:e1");
        assert_eq!(evidence.entity_uid, "sr:device:a");
        assert!(evidence.condition_met);
        assert_eq!(evidence.description, "Anomaly detected");
        assert!(evidence.last_updated_unix_ms > 0);
    }

    #[test]
    fn parses_capacity_prediction_with_record_id_fallback() {
        let evidence = parse_prediction_signal(&json!({
            "signal_type": "prediction",
            "event_type": "capacity_forecast",
            "event_id": "cap:e1",
            "routing_correlation": {"record_id": "disk_usage:host-a:/"},
            "explainability": {"reason": "disk will exhaust"}
        }))
        .expect("evidence");

        assert_eq!(evidence.entity_uid, "disk_usage:host-a:/");
        assert_eq!(evidence.description, "disk will exhaust");
    }

    #[test]
    fn parses_evidence_timestamp_from_payload() {
        let evidence = parse_prediction_signal(&json!({
            "signal_type": "prediction",
            "event_type": "anomaly",
            "source_identity": {"entity_uid": "sr:device:a"},
            "anomaly": {"observed_at_unix_nano": 1_781_260_800_123_000_000i64}
        }))
        .expect("evidence");

        assert_eq!(evidence.last_updated_unix_ms, 1_781_260_800_123);
    }

    #[test]
    fn rejects_non_evidence_predictions() {
        assert!(
            parse_prediction_signal(&json!({
                "signal_type": "prediction",
                "event_type": "root_cause",
                "source_identity": {"entity_uid": "sr:device:a"}
            }))
            .is_none()
        );
    }

    #[test]
    fn applies_evidence_idempotently() {
        let mut ctx = Context::default();
        let evidence = SignalEvidence {
            rule_id: "correlation:anomaly:e1".to_string(),
            entity_uid: "sr:device:a".to_string(),
            condition_met: true,
            description: "anomaly".to_string(),
            last_updated_unix_ms: 1_000,
        };

        assert!(apply_signal_evidence(&mut ctx, &evidence));
        assert_eq!(ctx.operator_rules.len(), 1);
        assert!(!apply_signal_evidence(&mut ctx, &evidence));
        assert_eq!(ctx.operator_rules.len(), 1);
    }

    #[test]
    fn prunes_stale_operator_rule_evidence() {
        let mut ctx = Context::default();
        let fresh = SignalEvidence {
            rule_id: "correlation:anomaly:fresh".to_string(),
            entity_uid: "sr:device:a".to_string(),
            condition_met: true,
            description: "fresh anomaly".to_string(),
            last_updated_unix_ms: 10_000,
        };
        let stale = SignalEvidence {
            rule_id: "correlation:anomaly:stale".to_string(),
            entity_uid: "sr:device:b".to_string(),
            condition_met: true,
            description: "stale anomaly".to_string(),
            last_updated_unix_ms: 1_000,
        };

        assert!(apply_signal_evidence(&mut ctx, &fresh));
        assert!(apply_signal_evidence(&mut ctx, &stale));

        let pruned = crate::domain_model::prune_stale_operator_rules(&mut ctx, 10_000, 5_000);

        assert_eq!(pruned, 1);
        assert_eq!(ctx.operator_rules.len(), 1);
        assert_eq!(ctx.operator_rules[0].rule_id, "correlation:anomaly:fresh");
    }

    #[test]
    fn prefers_stable_series_identity_over_per_event_id() {
        let first = parse_prediction_signal(&json!({
            "signal_type": "prediction",
            "event_type": "anomaly",
            "event_id": "anomaly:series-a:1781260800000000000:anomalous",
            "status": "open",
            "source_identity": {
                "entity_uid": "sr:device:a",
                "series_key": "sysmon:memory:host-a"
            },
            "routing_correlation": {"record_id": "sysmon:memory:host-a"},
            "message": "Anomaly detected"
        }))
        .expect("first evidence");

        let second = parse_prediction_signal(&json!({
            "signal_type": "prediction",
            "event_type": "anomaly",
            "event_id": "anomaly:series-a:1781260860000000000:anomalous",
            "status": "resolved",
            "source_identity": {
                "entity_uid": "sr:device:a",
                "series_key": "sysmon:memory:host-a"
            },
            "routing_correlation": {"record_id": "sysmon:memory:host-a"},
            "message": "Anomaly resolved"
        }))
        .expect("second evidence");

        assert_eq!(first.rule_id, second.rule_id);
        assert_eq!(first.rule_id, "correlation:anomaly:sysmon:memory:host-a");
        assert!(first.condition_met);
        assert!(!second.condition_met);
    }

    #[test]
    fn updates_existing_evidence_when_status_changes() {
        let mut ctx = Context::default();

        let open = SignalEvidence {
            rule_id: "correlation:anomaly:stable-finding".to_string(),
            entity_uid: "sr:device:a".to_string(),
            condition_met: true,
            description: "anomaly open".to_string(),
            last_updated_unix_ms: 1_000,
        };

        let resolved = SignalEvidence {
            condition_met: false,
            description: "anomaly resolved".to_string(),
            ..open.clone()
        };

        assert!(apply_signal_evidence(&mut ctx, &open));
        assert!(apply_signal_evidence(&mut ctx, &resolved));
        assert!(ctx.operator_rules.is_empty());
        assert!(!apply_signal_evidence(&mut ctx, &resolved));
    }
}
