//! Minimal SRQL DSL parser that converts the key:value syntax into a structured AST.

mod ast;
mod duration;
mod entity;
mod filters;
mod order;
mod stats;
#[cfg(test)]
mod tests;
mod tokens;

pub use ast::{
    DownsampleAgg, DownsampleSpec, Entity, Filter, FilterOp, FilterValue, OrderClause,
    OrderDirection, QueryAst, StatsAggType, StatsAggregation, StatsSpec,
};

// Entity stats builders parse their own `by` clause and projection, so they need
// the same duration grammar `bucket:` uses and the same paren-aware comma split.
// Sharing these keeps a builder from disagreeing with the parser about where one
// aggregation ends and the next begins.
pub(crate) use duration::parse_bucket_seconds as parse_group_bucket_seconds;
pub(crate) use stats::split_top_level_commas;

use crate::{
    error::{Result, ServiceError},
    time::parse_time_value,
};

use duration::{normalize_optional_string, parse_bucket_seconds, parse_downsample_agg};
use entity::parse_entity;
use filters::{MAX_FILTER_LIST_VALUES, build_filter};
use order::parse_order;
use stats::{MAX_STATS_EXPR_LEN, merge_stats_exprs, parse_stats_expr};
use tokens::{parse_value, split_token, tokenize};

pub fn parse(input: &str) -> Result<QueryAst> {
    let mut entity = None;
    let mut filters = Vec::new();
    let mut order = Vec::new();
    let mut limit = None;
    let mut time_filter = None;
    let mut stats = None;
    let mut downsample_bucket_seconds: Option<i64> = None;
    let mut downsample_agg = DownsampleAgg::Avg;
    let mut downsample_series: Option<String> = None;
    let mut downsample_value_field: Option<String> = None;
    let mut rollup_stats: Option<String> = None;
    let mut other = false;

    let mut tokens = tokenize(input).into_iter().peekable();
    while let Some(token) = tokens.next() {
        let (raw_key, raw_value) = split_token(&token)?;
        let key = raw_key.trim().to_lowercase();
        let value = parse_value(raw_value);

        match key.as_str() {
            "in" => {
                entity = Some(parse_entity(value.as_scalar()?)?);
            }
            "limit" => {
                let parsed = value
                    .as_scalar()?
                    .parse::<i64>()
                    .map_err(|_| ServiceError::InvalidRequest("invalid limit".into()))?;
                if parsed <= 0 {
                    return Err(ServiceError::InvalidRequest(
                        "limit must be a positive integer".into(),
                    ));
                }
                limit = Some(parsed);
            }
            "sort" | "order" => {
                order.extend(parse_order(value.as_scalar()?));
            }
            "time" | "timeframe" => {
                // `parse_value` treats bracketed ranges like `[start,end]` as a list, but the SRQL
                // time parser supports bracketed absolute ranges as a scalar string.
                // Use the raw token value so both presets (`last_1h`) and absolute ranges work.
                time_filter = Some(parse_time_value(raw_value)?);
            }
            "bucket" | "downsample" => {
                downsample_bucket_seconds = Some(parse_bucket_seconds(value.as_scalar()?)?);
            }
            "agg" => {
                downsample_agg = parse_downsample_agg(value.as_scalar()?)?;
            }
            "series" => {
                downsample_series = normalize_optional_string(value.as_scalar()?);
            }
            "value_field" | "value-field" => {
                downsample_value_field = normalize_optional_string(value.as_scalar()?);
            }
            "stats" => {
                let mut expr = value.as_scalar()?.to_string();

                // Handle "as alias" part.
                if tokens
                    .peek()
                    .is_some_and(|next| next.as_str().eq_ignore_ascii_case("as"))
                {
                    let _ = tokens.next();
                    let alias_token = tokens.next().ok_or_else(|| {
                        ServiceError::InvalidRequest(
                            "stats aliases must be of the form 'stats:expr as alias'".into(),
                        )
                    })?;
                    if alias_token.contains(':') {
                        return Err(ServiceError::InvalidRequest(
                            "stats aliases must be of the form 'stats:expr as alias'".into(),
                        ));
                    }

                    let alias = alias_token
                        .trim()
                        .trim_matches('"')
                        .trim_matches('\'')
                        .to_string();
                    if alias.is_empty() {
                        return Err(ServiceError::InvalidRequest(
                            "stats aliases must be of the form 'stats:expr as alias'".into(),
                        ));
                    }

                    expr.push_str(" as ");
                    expr.push_str(&alias);
                }

                // Handle "by field" part for GROUP BY.
                if tokens
                    .peek()
                    .is_some_and(|next| next.as_str().eq_ignore_ascii_case("by"))
                {
                    let _ = tokens.next();
                    let field_token = tokens.next().ok_or_else(|| {
                        ServiceError::InvalidRequest(
                            "stats group by must be of the form 'stats:expr as alias by field'"
                                .into(),
                        )
                    })?;
                    // A colon here usually means the group-by field was omitted
                    // and the next clause was swallowed instead, as in
                    // `stats:count() as n by limit:10`. The one legitimate colon
                    // is the `time:<duration>` bucket dimension, so allow that
                    // and keep refusing everything else.
                    if !group_by_colons_are_time_dimensions(field_token.as_str()) {
                        return Err(ServiceError::InvalidRequest(
                            "stats group by must be of the form 'stats:expr as alias by field'; \
                             only the 'time' dimension takes a duration"
                                .into(),
                        ));
                    }

                    let field = field_token
                        .trim()
                        .trim_matches('"')
                        .trim_matches('\'')
                        .to_string();
                    if field.is_empty() {
                        return Err(ServiceError::InvalidRequest(
                            "stats group by field cannot be empty".into(),
                        ));
                    }

                    expr.push_str(" by ");
                    expr.push_str(&field);
                }

                if expr.trim().len() > MAX_STATS_EXPR_LEN {
                    return Err(ServiceError::InvalidRequest(format!(
                        "stats expression must be <= {MAX_STATS_EXPR_LEN} characters"
                    )));
                }
                stats = match stats {
                    None => Some(parse_stats_expr(&expr)),
                    Some(existing) => {
                        let merged = merge_stats_exprs(existing.as_raw(), &expr)?;
                        Some(parse_stats_expr(&merged))
                    }
                };
            }
            "rollup_stats" => {
                let stat_type = value.as_scalar()?.trim().to_lowercase();
                if stat_type.is_empty() {
                    return Err(ServiceError::InvalidRequest(
                        "rollup_stats requires a type (e.g., rollup_stats:severity)".into(),
                    ));
                }
                rollup_stats = Some(stat_type);
            }
            "other" => {
                other = parse_bool_flag(value.as_scalar()?, "other")?;
            }
            "window" | "bounded" | "mode" => {
                // Aggregations and streaming hints are ignored for now.
                continue;
            }
            _ => {
                if let FilterValue::List(ref items) = value {
                    if items.is_empty() {
                        return Err(ServiceError::InvalidRequest(
                            "list filters must contain at least one value".into(),
                        ));
                    }
                    if items.len() > MAX_FILTER_LIST_VALUES {
                        return Err(ServiceError::InvalidRequest(format!(
                            "list filters support at most {MAX_FILTER_LIST_VALUES} values"
                        )));
                    }
                }
                filters.push(build_filter(raw_key, value));
            }
        }
    }

    let entity = entity.ok_or_else(|| {
        ServiceError::InvalidRequest("queries must include an in:<entity> token".into())
    })?;

    let downsample = downsample_bucket_seconds.map(|bucket_seconds| DownsampleSpec {
        bucket_seconds,
        agg: downsample_agg,
        series: downsample_series,
        value_field: downsample_value_field,
    });

    Ok(QueryAst {
        entity,
        filters,
        order,
        limit,
        time_filter,
        stats,
        downsample,
        rollup_stats,
        other,
    })
}

fn parse_bool_flag(raw: &str, key: &str) -> Result<bool> {
    match raw.trim().to_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "{key} expects boolean true/false, got '{other}'"
        ))),
    }
}

/// Whether every colon in a stats `by` token belongs to a `time:<duration>`
/// dimension.
///
/// Entity stats builders validate the duration itself; this only decides whether
/// the token is a group-by clause at all, or a following clause that was
/// swallowed because the field was omitted.
fn group_by_colons_are_time_dimensions(token: &str) -> bool {
    token.split(',').all(|segment| {
        let segment = segment.trim();
        match segment.split_once(':') {
            None => true,
            Some((key, value)) => {
                key.trim().eq_ignore_ascii_case("time") && !value.trim().is_empty()
            }
        }
    })
}
