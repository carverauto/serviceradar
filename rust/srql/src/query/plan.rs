use super::{QueryPlan, QueryRequest, max_time_range_days_for_ast};
use crate::{
    config::AppConfig,
    error::{Result, ServiceError},
    pagination::decode_cursor,
    parser::{Entity, Filter, QueryAst},
    time::TimeRange,
};
use chrono::{Duration as ChronoDuration, Utc};

pub(crate) fn build_query_plan(
    config: &AppConfig,
    request: &QueryRequest,
    ast: QueryAst,
) -> Result<QueryPlan> {
    let exhaustive_profile_query = is_exhaustive_profile_stats(ast.stats.as_ref());
    let requested_limit = request.limit.or(ast.limit);
    if ast.other {
        validate_other_rollup_request(&ast, requested_limit, request.cursor.as_deref())?;
    }

    let limit = if is_grouped_device_stats(&ast) {
        determine_grouped_device_limit(config, requested_limit)
    } else {
        determine_limit(config, requested_limit)
    };
    let offset = request
        .cursor
        .as_deref()
        .map(|cursor| {
            decode_cursor(
                cursor,
                &config.cursor_secret,
                if exhaustive_profile_query {
                    i64::MAX
                } else {
                    config.max_cursor_offset
                },
            )
        })
        .transpose()?
        .unwrap_or(0)
        .max(0);
    let max_time_range_days = max_time_range_days_for_ast(&ast);
    let now = Utc::now();
    let time_range = ast
        .time_filter
        .map(|spec| spec.resolve_with_max_days(now, max_time_range_days))
        .transpose()?;
    let time_range = default_time_range_for_entity(&ast.entity, time_range, now, &ast.filters);

    let (filters, order, downsample) =
        normalize_device_aliases(&ast.entity, ast.filters, ast.order, ast.downsample);
    let (filters, include_deleted) = extract_include_deleted(filters)?;
    let filters = normalize_telemetry_id_filters(&ast.entity, filters)?;

    Ok(QueryPlan {
        entity: ast.entity,
        filters,
        order,
        limit,
        offset,
        time_range,
        stats: ast.stats,
        downsample,
        rollup_stats: ast.rollup_stats,
        other: ast.other,
        include_deleted,
    })
}

/// Shared by cursor decoding, execution, and translation to avoid truncating
/// seasonal discovery or rejecting a continuation minted by another path.
/// The caller-visible contract lives in docs/docs/srql-language-reference.md
/// under Sorting and pagination.
pub(crate) fn is_exhaustive_profile_query(plan: &QueryPlan) -> bool {
    is_exhaustive_profile_stats(plan.stats.as_ref())
}

fn is_exhaustive_profile_stats(stats: Option<&crate::parser::StatsSpec>) -> bool {
    stats
        .map(|stats| {
            let raw = stats.as_raw().trim_start().to_ascii_lowercase();
            raw.starts_with("profile_hour_of_week_full(")
                || raw.starts_with("profile_hour_of_week(")
        })
        .unwrap_or(false)
}

fn validate_other_rollup_request(
    ast: &QueryAst,
    requested_limit: Option<i64>,
    cursor: Option<&str>,
) -> Result<()> {
    if !matches!(
        ast.entity,
        Entity::Flows
            | Entity::AttributedFlows
            | Entity::TimeseriesMetrics
            | Entity::SnmpMetrics
            | Entity::RperfMetrics
    ) {
        return Err(ServiceError::InvalidRequest(
            "other:true is currently supported only for flow or timeseries stats".into(),
        ));
    }

    ast.stats.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("other:true requires a grouped stats query".into())
    })?;

    if requested_limit.is_none() {
        return Err(ServiceError::InvalidRequest(
            "other:true requires an explicit limit".into(),
        ));
    }

    if ast.order.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "other:true requires an explicit sort".into(),
        ));
    }

    if cursor.is_some() {
        return Err(ServiceError::InvalidRequest(
            "other:true does not support cursor pagination".into(),
        ));
    }

    Ok(())
}

fn default_time_range_for_entity(
    entity: &Entity,
    time_range: Option<TimeRange>,
    now: chrono::DateTime<Utc>,
    filters: &[Filter],
) -> Option<TimeRange> {
    match (entity, time_range) {
        (Entity::Logs, None) => Some(TimeRange {
            start: now - ChronoDuration::hours(24),
            end: now,
        }),
        (Entity::Flows | Entity::AttributedFlows, None) if has_threat_filter(filters) => {
            Some(TimeRange {
                start: now - ChronoDuration::hours(24),
                end: now,
            })
        }
        (_, range) => range,
    }
}

fn has_threat_filter(filters: &[Filter]) -> bool {
    filters.iter().any(|filter| {
        matches!(
            filter.field.as_str(),
            "threat_matched"
                | "threat_source"
                | "threat_indicator"
                | "threat_observed_ip"
                | "threat_severity"
        )
    })
}

fn determine_limit(config: &AppConfig, candidate: Option<i64>) -> i64 {
    let default = config.default_limit;
    let max = config.max_limit;
    let limit = candidate.unwrap_or(default).max(1);
    if max <= 0 { limit } else { limit.min(max) }
}

fn is_grouped_device_stats(ast: &QueryAst) -> bool {
    matches!(ast.entity, Entity::Devices)
        && ast.stats.as_ref().is_some_and(|stats| {
            stats
                .as_raw()
                .split_whitespace()
                .nth(3)
                .is_some_and(|token| token.eq_ignore_ascii_case("by"))
        })
}

fn determine_grouped_device_limit(config: &AppConfig, candidate: Option<i64>) -> i64 {
    const DEFAULT_GROUP_LIMIT: i64 = 20;
    const MAX_GROUP_LIMIT: i64 = 100;

    let configured_max = if config.max_limit > 0 {
        config.max_limit.min(MAX_GROUP_LIMIT)
    } else {
        MAX_GROUP_LIMIT
    }
    .max(1);

    candidate
        .unwrap_or(DEFAULT_GROUP_LIMIT)
        .max(1)
        .min(configured_max)
}

fn normalize_device_aliases(
    entity: &Entity,
    filters: Vec<crate::parser::Filter>,
    order: Vec<crate::parser::OrderClause>,
    downsample: Option<crate::parser::DownsampleSpec>,
) -> (
    Vec<crate::parser::Filter>,
    Vec<crate::parser::OrderClause>,
    Option<crate::parser::DownsampleSpec>,
) {
    let filters = filters
        .into_iter()
        .map(|mut filter| {
            if let Some(mapped) = normalize_device_field(entity, &filter.field) {
                filter.field = mapped;
            }
            filter
        })
        .collect();

    let order = order
        .into_iter()
        .map(|mut clause| {
            if let Some(mapped) = normalize_device_field(entity, &clause.field) {
                clause.field = mapped;
            }
            clause
        })
        .collect();

    let downsample = downsample.map(|mut spec| {
        if let Some(series) = spec.series.as_mut()
            && let Some(mapped) = normalize_device_field(entity, series)
        {
            *series = mapped;
        }
        spec
    });

    (filters, order, downsample)
}

fn extract_include_deleted(filters: Vec<Filter>) -> Result<(Vec<Filter>, bool)> {
    let mut include_deleted = false;
    let mut remaining = Vec::with_capacity(filters.len());

    for filter in filters {
        if filter.field.eq_ignore_ascii_case("include_deleted") {
            if !matches!(filter.op, crate::parser::FilterOp::Eq) {
                return Err(ServiceError::InvalidRequest(
                    "include_deleted only supports equality".into(),
                ));
            }

            let raw = filter.value.as_scalar()?;
            include_deleted = parse_bool_str(raw)?;
        } else {
            remaining.push(filter);
        }
    }

    Ok((remaining, include_deleted))
}

fn parse_bool_str(value: &str) -> Result<bool> {
    match value.to_lowercase().as_str() {
        "true" | "1" | "yes" | "y" => Ok(true),
        "false" | "0" | "no" | "n" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{value}'"
        ))),
    }
}

/// Observability entities whose trace/span identifier filters follow the
/// canonical OTel id contract (32-char lowercase hex trace ids, 16-char
/// lowercase hex span ids).
fn entity_uses_telemetry_ids(entity: &Entity) -> bool {
    matches!(
        entity,
        Entity::Traces | Entity::Logs | Entity::OtelMetrics | Entity::TraceSummaries
    )
}

/// Returns `(canonical_field_name, expected_hex_length)` for telemetry id
/// filter fields on observability entities.
fn telemetry_id_spec(entity: &Entity, field: &str) -> Option<(&'static str, usize)> {
    if !entity_uses_telemetry_ids(entity) {
        return None;
    }
    match field {
        "trace_id" => Some(("trace_id", 32)),
        "span_id" => Some(("span_id", 16)),
        "parent_span_id" => Some(("parent_span_id", 16)),
        "root_span_id" => Some(("root_span_id", 16)),
        _ => None,
    }
}

/// Normalizes trace/span id filter values on observability entities before
/// SQL generation: case-folds hex input to lowercase and rejects values that
/// are not well-formed ids (32-char hex for trace ids, 16-char hex for span
/// ids). Empty values are rejected so a query errors loudly instead of
/// silently matching nothing. LIKE patterns are case-folded and restricted to
/// hex digits plus SQL wildcards.
fn normalize_telemetry_id_filters(entity: &Entity, filters: Vec<Filter>) -> Result<Vec<Filter>> {
    filters
        .into_iter()
        .map(|mut filter| {
            let Some((field, len)) = telemetry_id_spec(entity, filter.field.as_str()) else {
                return Ok(filter);
            };

            match filter.op {
                crate::parser::FilterOp::Eq
                | crate::parser::FilterOp::NotEq
                | crate::parser::FilterOp::In
                | crate::parser::FilterOp::NotIn => {
                    filter.value = match filter.value {
                        crate::parser::FilterValue::Scalar(value) => {
                            crate::parser::FilterValue::Scalar(normalize_telemetry_id_value(
                                field, len, &value,
                            )?)
                        }
                        crate::parser::FilterValue::List(values) => {
                            crate::parser::FilterValue::List(
                                values
                                    .iter()
                                    .map(|value| normalize_telemetry_id_value(field, len, value))
                                    .collect::<Result<Vec<_>>>()?,
                            )
                        }
                    };
                }
                crate::parser::FilterOp::Like | crate::parser::FilterOp::NotLike => {
                    if let crate::parser::FilterValue::Scalar(value) = &filter.value {
                        filter.value = crate::parser::FilterValue::Scalar(
                            normalize_telemetry_id_pattern(field, len, value)?,
                        );
                    }
                }
                // Other operators are rejected downstream by the per-entity
                // text-filter handling; leave the value untouched here.
                _ => {}
            }

            Ok(filter)
        })
        .collect()
}

fn normalize_telemetry_id_value(field: &str, len: usize, raw: &str) -> Result<String> {
    let value = raw.trim().to_ascii_lowercase();
    if value.is_empty() {
        return Err(ServiceError::InvalidRequest(format!(
            "{field} filter value must not be empty; expected a {len}-character hex string"
        )));
    }
    if value.len() != len || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid {field} '{raw}': expected a {len}-character hex string"
        )));
    }
    Ok(value)
}

fn normalize_telemetry_id_pattern(field: &str, len: usize, raw: &str) -> Result<String> {
    let pattern = raw.trim().to_ascii_lowercase();
    if pattern.is_empty() {
        return Err(ServiceError::InvalidRequest(format!(
            "{field} filter value must not be empty; expected a {len}-character hex string"
        )));
    }
    if !pattern
        .bytes()
        .all(|b| b.is_ascii_hexdigit() || b == b'%' || b == b'_')
    {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid {field} pattern '{raw}': expected hex digits (optionally with % or _ wildcards); full ids are {len}-character hex strings"
        )));
    }
    Ok(pattern)
}

fn normalize_device_field(entity: &Entity, field: &str) -> Option<String> {
    // Agents have their own uid field, don't remap
    if matches!(entity, Entity::Agents) {
        return None;
    }
    if field.eq_ignore_ascii_case("uid") && !matches!(entity, Entity::Devices) {
        Some("device_id".to_string())
    } else if field.eq_ignore_ascii_case("device_id") && matches!(entity, Entity::Devices) {
        Some("uid".to_string())
    } else {
        None
    }
}
