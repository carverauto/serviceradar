//! Plans for fleet models executed by web-ng through scoped Ash reads.

use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, FilterOp, FilterValue},
};
use serde_json::{Value, json};

pub(super) fn is_entity(entity: &Entity) -> bool {
    matches!(entity, Entity::AddonFleet | Entity::PluginFleet)
}

#[derive(Clone, Copy)]
pub(super) enum Kind {
    Text,
    Bool,
    Int,
    Time,
}

pub(super) fn fields(entity: &Entity) -> Vec<(&'static str, Kind)> {
    use Kind::*;
    let mut fields = vec![
        ("agent_uid", Text),
        ("assigned", Bool),
        ("enabled", Bool),
        ("package_id", Text),
        ("package_status", Text),
        ("content_hash", Text),
        ("assigned_version", Text),
        ("observed_version", Text),
        ("observed_state", Text),
        ("category", Text),
        ("reason_code", Text),
        ("reported_at", Time),
        ("evidence_age_seconds", Int),
        ("stale", Bool),
        ("version_drift", Bool),
    ];
    if matches!(entity, Entity::AddonFleet) {
        fields.extend([
            ("agent_label", Text),
            ("addon_id", Text),
            ("addon_name", Text),
            ("active", Bool),
            ("degradation_reason", Text),
            ("last_health_at", Time),
            ("last_scan_at", Time),
            ("rollout_state", Text),
            ("update_policy", Text),
            ("latest_approved_version", Text),
            ("verification_status", Text),
        ]);
    } else {
        fields.extend([
            ("partition_id", Text),
            ("plugin_id", Text),
            ("plugin_name", Text),
            ("assignment_id", Text),
            ("source", Text),
            ("policy_id", Text),
            ("observed_assignment_id", Text),
            ("assignment_drift", Bool),
            ("interval_seconds", Int),
            ("timeout_seconds", Int),
            ("available", Bool),
            ("result_status", Text),
            ("last_success_at", Time),
            ("last_failure_at", Time),
            ("last_error", Text),
            ("runtime", Text),
            ("outputs", Text),
        ]);
    }
    fields
}

pub(super) fn read_plan(plan: &QueryPlan) -> Result<Value> {
    if plan.stats.is_some()
        || plan.downsample.is_some()
        || plan.rollup_stats.is_some()
        || plan.other
    {
        return Err(ServiceError::InvalidRequest(
            "fleet queries do not support aggregation".into(),
        ));
    }
    let fields = fields(&plan.entity);
    let kind_for = |field: &str| -> Result<Kind> {
        fields
            .iter()
            .find(|(name, _)| *name == field)
            .map(|(_, kind)| *kind)
            .ok_or_else(|| {
                ServiceError::InvalidRequest(format!("unsupported fleet field: '{field}'"))
            })
    };
    let filters = plan
        .filters
        .iter()
        .map(|filter| {
            let kind = kind_for(&filter.field)?;
            let allowed = match filter.op {
                FilterOp::Eq | FilterOp::NotEq | FilterOp::In | FilterOp::NotIn => true,
                FilterOp::Like | FilterOp::NotLike => matches!(kind, Kind::Text),
                _ => matches!(kind, Kind::Int | Kind::Time),
            };
            if !allowed {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported operator for fleet field: '{}'",
                    filter.field
                )));
            }
            let value = match (&filter.op, &filter.value) {
                (FilterOp::In | FilterOp::NotIn, FilterValue::List(values)) => Value::Array(
                    values
                        .iter()
                        .map(|value| parse_value(value, kind))
                        .collect::<Result<Vec<_>>>()?,
                ),
                (FilterOp::In | FilterOp::NotIn, _) | (_, FilterValue::List(_)) => {
                    return Err(ServiceError::InvalidRequest(
                        "invalid fleet filter value shape".into(),
                    ));
                }
                (_, FilterValue::Scalar(value)) => parse_value(value, kind)?,
            };
            Ok(json!({"field": filter.field, "op": filter.op, "value": value}))
        })
        .collect::<Result<Vec<_>>>()?;
    for clause in &plan.order {
        kind_for(&clause.field)?;
    }
    let mut order = if plan.order.is_empty() {
        let identity = if matches!(plan.entity, Entity::AddonFleet) {
            "addon_id"
        } else {
            "plugin_id"
        };
        vec![
            json!({"field": "category", "direction": "asc"}),
            json!({"field": "agent_uid", "direction": "asc"}),
            json!({"field": identity, "direction": "asc"}),
        ]
    } else {
        plan.order.iter().map(|clause| json!(clause)).collect()
    };
    let identity_fields = if matches!(plan.entity, Entity::AddonFleet) {
        vec!["agent_uid", "addon_id"]
    } else {
        vec!["partition_id", "agent_uid", "plugin_id"]
    };
    for field in identity_fields {
        if !order.iter().any(|clause| clause["field"] == field) {
            order.push(json!({"field": field, "direction": "asc"}));
        }
    }
    Ok(json!({
        "entity": plan.entity, "filters": filters, "order": order,
        "fields": fields.iter().map(|(name, _)| *name).collect::<Vec<_>>(),
        "limit": plan.limit, "offset": plan.offset,
        "time_range": plan.time_range.as_ref().map(|range| json!({
            "start": range.start.to_rfc3339(), "end": range.end.to_rfc3339()
        }))
    }))
}

fn parse_value(value: &str, kind: Kind) -> Result<Value> {
    let invalid = || ServiceError::InvalidRequest(format!("invalid fleet filter value: '{value}'"));
    match kind {
        Kind::Text => Ok(json!(value)),
        Kind::Bool => match value.to_ascii_lowercase().as_str() {
            "true" => Ok(json!(true)),
            "false" => Ok(json!(false)),
            _ => Err(invalid()),
        },
        Kind::Int => value
            .parse::<i64>()
            .map(|value| json!(value))
            .map_err(|_| invalid()),
        Kind::Time => chrono::DateTime::parse_from_rfc3339(value)
            .map(|value| json!(value.to_rfc3339()))
            .map_err(|_| invalid()),
    }
}
