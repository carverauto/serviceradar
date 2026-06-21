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

/// Validates that a JSONB key is safe to use in a query.
/// Only allows alphanumeric characters, underscores, and hyphens.
pub(in crate::query::devices) fn is_valid_jsonb_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 64
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Applies a text filter to a JSONB field path using the ->> operator.
/// Supports equality, inequality, and LIKE operations.
pub(super) fn apply_jsonb_text_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    column: &str,
    key: &str,
) -> Result<DeviceQuery<'a>> {
    // Construct the JSONB text extraction expression: column->>'key'
    let jsonb_expr = format!("{column}->>'{key}'");
    let value = filter.value.as_scalar()?.to_string();

    match filter.op {
        FilterOp::Eq => {
            let expr = sql::<Bool>(&format!("{jsonb_expr} = ")).bind::<Text, _>(value);
            Ok(query.filter(expr))
        }
        FilterOp::NotEq => {
            let expr = sql::<Bool>(&format!("({jsonb_expr} IS NULL OR {jsonb_expr} != "))
                .bind::<Text, _>(value)
                .sql(")");
            Ok(query.filter(expr))
        }
        FilterOp::Like => {
            let expr = sql::<Bool>(&format!("{jsonb_expr} ILIKE ")).bind::<Text, _>(value);
            Ok(query.filter(expr))
        }
        FilterOp::NotLike => {
            let expr = sql::<Bool>(&format!("({jsonb_expr} IS NULL OR {jsonb_expr} NOT ILIKE "))
                .bind::<Text, _>(value)
                .sql(")");
            Ok(query.filter(expr))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "JSONB field '{column}.{key}' only supports equality and LIKE filters"
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
