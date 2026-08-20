use super::super::DeviceQuery;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
};
use diesel::{
    dsl::{not, sql},
    prelude::*,
    sql_types::{Array, Bool, Text},
};

pub(in crate::query::devices) fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{raw}'"
        ))),
    }
}

/// Re-exported from the shared filter helpers so `devices` and
/// `timeseries_metrics` validate JSONB keys identically.
pub(in crate::query::devices) use crate::query::filters_common::is_valid_jsonb_key;

/// Applies a text filter to a JSONB field path using the ->> operator.
/// Supports equality, inequality, LIKE, and list membership.
pub(super) fn apply_jsonb_text_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    column: &str,
    key: &str,
) -> Result<DeviceQuery<'a>> {
    // Construct the JSONB text extraction expression: column->>'key'
    let jsonb_expr = format!("{column}->>'{key}'");

    match filter.op {
        FilterOp::Eq => {
            let value = filter.value.as_scalar()?.to_string();
            let expr = sql::<Bool>(&format!("{jsonb_expr} = ")).bind::<Text, _>(value);
            Ok(query.filter(expr))
        }
        FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            let expr = sql::<Bool>(&format!("({jsonb_expr} IS NULL OR {jsonb_expr} != "))
                .bind::<Text, _>(value)
                .sql(")");
            Ok(query.filter(expr))
        }
        FilterOp::Like => {
            let value = filter.value.as_scalar()?.to_string();
            let expr = sql::<Bool>(&format!("{jsonb_expr} ILIKE ")).bind::<Text, _>(value);
            Ok(query.filter(expr))
        }
        FilterOp::NotLike => {
            let value = filter.value.as_scalar()?.to_string();
            let expr = sql::<Bool>(&format!("({jsonb_expr} IS NULL OR {jsonb_expr} NOT ILIKE "))
                .bind::<Text, _>(value)
                .sql(")");
            Ok(query.filter(expr))
        }
        // List form, e.g. tags.gate:(B40,B41). An empty list is a no-op filter
        // rather than a query that can never match, matching how the
        // discovery_sources list filter behaves.
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(query);
            }

            if matches!(filter.op, FilterOp::NotIn) {
                // Devices missing the key entirely are "not in" the list; the
                // bare `!=` form would drop them because NULL != x is NULL.
                let expr = sql::<Bool>(&format!(
                    "({jsonb_expr} IS NULL OR NOT ({jsonb_expr} = ANY("
                ))
                .bind::<Array<Text>, _>(values)
                .sql(")))");
                Ok(query.filter(expr))
            } else {
                let expr = sql::<Bool>(&format!("{jsonb_expr} = ANY("))
                    .bind::<Array<Text>, _>(values)
                    .sql(")");
                Ok(query.filter(expr))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "JSONB field '{column}.{key}' only supports equality, LIKE, and list filters"
        ))),
    }
}

pub(super) fn apply_tags_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let tag = filter.value.as_scalar()?.to_string();
            let expr = sql::<Bool>("coalesce(tags, '{}'::jsonb) ? ").bind::<Text, _>(tag);
            if matches!(filter.op, FilterOp::NotEq) {
                Ok(query.filter(not(expr)))
            } else {
                Ok(query.filter(expr))
            }
        }
        FilterOp::In | FilterOp::NotIn => {
            let tags = filter.value.as_list()?.to_vec();
            if tags.is_empty() {
                return Ok(query);
            }
            let expr = sql::<Bool>("coalesce(tags, '{}'::jsonb) ?| ").bind::<Array<Text>, _>(tags);
            if matches!(filter.op, FilterOp::NotIn) {
                Ok(query.filter(not(expr)))
            } else {
                Ok(query.filter(expr))
            }
        }
        _ => Err(ServiceError::InvalidRequest(
            "tags filter only supports equality and list filters".into(),
        )),
    }
}
