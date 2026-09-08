//! Live state-change deltas (task 1.2b).
//!
//! Parses the `signals.state.<table>` envelopes published by core-elx's
//! `StateChangePublisher` (Phase 0, Decision 1) into typed deltas and applies
//! them to the in-memory `Context` between full `EmbeddedSrql` snapshots. The
//! async JetStream subscriber that drives this lands as the next sub-step of 1.2.

use serde_json::Value;

use crate::domain_model::Context;

/// A parsed state transition from a `signals.state.<table>` envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateChangeDelta {
    /// Source current-state table (e.g. `ocsf_devices`, `service_state`).
    pub table: String,
    /// Canonical entity id the transition applies to.
    pub entity_uid: String,
    /// The field that changed (e.g. `is_available`).
    pub field: String,
    /// The new value (as published in `explainability.new`).
    pub new_value: Value,
}

/// Parse a `signals.state.<table>` envelope (the `StateChangePublisher` shape)
/// into a delta. Returns `None` when the envelope is not a usable transition.
pub fn parse_state_change(envelope: &Value) -> Option<StateChangeDelta> {
    let identity = envelope.get("source_identity")?;
    let table = identity.get("table")?.as_str()?.to_string();
    let entity_uid = identity.get("entity_uid")?.as_str()?.to_string();

    let explain = envelope.get("explainability")?;
    let field = explain.get("field")?.as_str()?.to_string();
    let new_value = explain.get("new").cloned().unwrap_or(Value::Null);

    if entity_uid.is_empty() || field.is_empty() {
        return None;
    }

    Some(StateChangeDelta {
        table,
        entity_uid,
        field,
        new_value,
    })
}

/// Apply a delta to the in-memory `Context`. Returns `true` if a known entity
/// field was updated. Unknown tables/fields are ignored (coverage broadens as
/// the hydrator's entity set grows).
pub fn apply_delta(ctx: &mut Context, delta: &StateChangeDelta) -> bool {
    match delta.table.as_str() {
        "ocsf_devices" => apply_device_delta(ctx, delta),
        "service_state" => apply_service_delta(ctx, delta),
        _ => false,
    }
}

fn apply_device_delta(ctx: &mut Context, delta: &StateChangeDelta) -> bool {
    let Some(device) = ctx.devices.iter_mut().find(|d| d.uid == delta.entity_uid) else {
        return false;
    };
    match delta.field.as_str() {
        "is_available" => {
            device.is_available = delta.new_value.as_bool();
            true
        }
        "is_managed" => {
            device.is_managed = delta.new_value.as_bool();
            true
        }
        _ => false,
    }
}

fn apply_service_delta(ctx: &mut Context, delta: &StateChangeDelta) -> bool {
    let Some(service) = ctx.services.iter_mut().find(|s| s.id == delta.entity_uid) else {
        return false;
    };
    match delta.field.as_str() {
        "available" => {
            service.available = delta.new_value.as_bool();
            true
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain_model::{Context, Device, Service};
    use serde_json::json;

    fn state_change_envelope(table: &str, entity_uid: &str, field: &str, new: Value) -> Value {
        json!({
            "signal_type": "state_change",
            "source_identity": { "table": table, "entity_uid": entity_uid },
            "explainability": { "field": field, "old": Value::Null, "new": new }
        })
    }

    #[test]
    fn parses_a_device_transition() {
        let d = parse_state_change(&state_change_envelope(
            "ocsf_devices",
            "sr:device:abc",
            "is_available",
            json!(false),
        ))
        .expect("delta");

        assert_eq!(d.table, "ocsf_devices");
        assert_eq!(d.entity_uid, "sr:device:abc");
        assert_eq!(d.field, "is_available");
        assert_eq!(d.new_value, json!(false));
    }

    #[test]
    fn rejects_malformed_envelopes() {
        assert!(parse_state_change(&json!({})).is_none());
        assert!(
            parse_state_change(&state_change_envelope(
                "ocsf_devices",
                "",
                "is_available",
                json!(true)
            ))
            .is_none()
        );
    }

    #[test]
    fn applies_device_availability_transition() {
        let mut ctx = Context {
            devices: vec![Device {
                uid: "sr:device:abc".to_string(),
                is_available: Some(true),
                is_managed: Some(true),
                ..Default::default()
            }],
            ..Default::default()
        };

        let delta = parse_state_change(&state_change_envelope(
            "ocsf_devices",
            "sr:device:abc",
            "is_available",
            json!(false),
        ))
        .unwrap();

        assert!(apply_delta(&mut ctx, &delta));
        assert_eq!(ctx.devices[0].is_available, Some(false));
    }

    #[test]
    fn applies_service_availability_transition() {
        let mut ctx = Context {
            services: vec![Service {
                id: "agent-1:grpc:datasvc".to_string(),
                available: Some(true),
            }],
            ..Default::default()
        };

        let delta = parse_state_change(&state_change_envelope(
            "service_state",
            "agent-1:grpc:datasvc",
            "available",
            json!(false),
        ))
        .unwrap();

        assert!(apply_delta(&mut ctx, &delta));
        assert_eq!(ctx.services[0].available, Some(false));
    }

    #[test]
    fn ignores_unknown_entity_or_table() {
        let mut ctx = Context::default();
        let delta = parse_state_change(&state_change_envelope(
            "ocsf_devices",
            "sr:device:missing",
            "is_available",
            json!(false),
        ))
        .unwrap();
        assert!(!apply_delta(&mut ctx, &delta)); // no matching device

        let unknown = StateChangeDelta {
            table: "some_hypertable".to_string(),
            entity_uid: "x".to_string(),
            field: "y".to_string(),
            new_value: json!(1),
        };
        assert!(!apply_delta(&mut ctx, &unknown));
    }
}
