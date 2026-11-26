//! Read-model plan compiler for `in:camera_observations` executed by web-ng through scoped Ash queries.

use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, FilterOp, FilterValue},
};
use serde_json::{Value, json};

pub(super) fn is_entity(entity: &Entity) -> bool {
    matches!(entity, Entity::CameraObservations)
}

#[derive(Clone, Copy)]
pub(super) enum Kind {
    Text,
    Bool,
    Int,
    Float,
    Time,
}

const FILTER_ONLY_FIELDS: &[(&str, Kind)] = &[("search", Kind::Text)];

pub(super) fn output_fields() -> Vec<(&'static str, Kind)> {
    use Kind::*;
    vec![
        ("id", Text),
        ("observation_key", Text),
        ("pack_id", Text),
        ("pipeline_id", Text),
        ("pipeline_version", Text),
        ("worker_kind", Text),
        ("worker_id", Text),
        ("model_id", Text),
        ("model_version", Text),
        ("job_id", Text),
        ("catalog_entry_id", Text),
        ("camera_source_id", Text),
        ("camera_display_name", Text),
        ("stream_profile_id", Text),
        ("source_mode", Text),
        ("fragment_sequence", Int),
        ("frame_sequence", Int),
        ("media_pts_ns", Int),
        ("timeline_ts_us", Int),
        ("time_basis", Text),
        ("track_id", Text),
        ("category", Text),
        ("label", Text),
        ("confidence", Float),
        ("signal_schema_id", Text),
        ("signal_schema_version", Text),
        ("display_contract_id", Text),
        ("has_crop", Bool),
        ("inserted_at", Time),
        ("updated_at", Time),
    ]
}

fn extra_projected_fields() -> &'static [&'static str] {
    &["bbox", "attributes"]
}

fn filter_kind_for(field: &str) -> Result<Kind> {
    output_fields()
        .into_iter()
        .chain(FILTER_ONLY_FIELDS.iter().copied())
        .find(|(name, _)| *name == field)
        .map(|(_, kind)| kind)
        .ok_or_else(|| {
            ServiceError::InvalidRequest(format!(
                "unsupported camera_observations field: '{field}'"
            ))
        })
}

fn sort_kind_for(field: &str) -> Result<Kind> {
    if field == "search" {
        return Err(ServiceError::InvalidRequest(
            "cannot sort camera_observations by filter-only field 'search'".into(),
        ));
    }
    output_fields()
        .into_iter()
        .find(|(name, _)| *name == field)
        .map(|(_, kind)| kind)
        .ok_or_else(|| {
            ServiceError::InvalidRequest(format!(
                "unsupported camera_observations sort field: '{field}'"
            ))
        })
}

pub(super) fn read_plan(plan: &QueryPlan) -> Result<Value> {
    if plan.stats.is_some()
        || plan.downsample.is_some()
        || plan.rollup_stats.is_some()
        || plan.other
    {
        return Err(ServiceError::InvalidRequest(
            "camera_observations queries do not support aggregation".into(),
        ));
    }

    let filters = plan
        .filters
        .iter()
        .map(|filter| {
            let kind = filter_kind_for(&filter.field)?;
            let allowed = match filter.op {
                FilterOp::Eq | FilterOp::NotEq | FilterOp::In | FilterOp::NotIn => true,
                FilterOp::Like | FilterOp::NotLike => matches!(kind, Kind::Text),
                _ => matches!(kind, Kind::Int | Kind::Float | Kind::Time),
            };
            if !allowed {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported operator for camera_observations field: '{}'",
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
                        "invalid camera_observations filter value shape".into(),
                    ));
                }
                (_, FilterValue::Scalar(value)) => parse_value(value, kind)?,
            };
            Ok(json!({"field": filter.field, "op": filter.op, "value": value}))
        })
        .collect::<Result<Vec<_>>>()?;

    for clause in &plan.order {
        sort_kind_for(&clause.field)?;
    }

    let mut order = if plan.order.is_empty() {
        vec![
            json!({"field": "timeline_ts_us", "direction": "desc"}),
            json!({"field": "id", "direction": "desc"}),
        ]
    } else {
        plan.order.iter().map(|clause| json!(clause)).collect()
    };

    if !order.iter().any(|clause| clause["field"] == "id") {
        order.push(json!({"field": "id", "direction": "desc"}));
    }

    let mut fields: Vec<&'static str> = output_fields().into_iter().map(|(name, _)| name).collect();
    fields.extend(extra_projected_fields());

    Ok(json!({
        "entity": "camera_observations",
        "filters": filters,
        "order": order,
        "fields": fields,
        "limit": plan.limit,
        "offset": plan.offset,
        "time_range": plan.time_range.as_ref().map(|range| json!({
            "start": range.start.to_rfc3339(),
            "end": range.end.to_rfc3339()
        }))
    }))
}

fn parse_value(value: &str, kind: Kind) -> Result<Value> {
    let invalid = || {
        ServiceError::InvalidRequest(format!(
            "invalid camera_observations filter value: '{value}'"
        ))
    };
    match kind {
        Kind::Text => Ok(json!(value)),
        Kind::Bool => match value.to_ascii_lowercase().as_str() {
            "true" => Ok(json!(true)),
            "false" => Ok(json!(false)),
            _ => Err(invalid()),
        },
        Kind::Int => value
            .parse::<i64>()
            .map(|parsed| json!(parsed))
            .map_err(|_| invalid()),
        Kind::Float => {
            let parsed = value.parse::<f64>().map_err(|_| invalid())?;
            if parsed.is_finite() {
                Ok(json!(parsed))
            } else {
                Err(invalid())
            }
        }
        Kind::Time => chrono::DateTime::parse_from_rfc3339(value)
            .map(|parsed| json!(parsed.to_rfc3339()))
            .map_err(|_| invalid()),
    }
}
