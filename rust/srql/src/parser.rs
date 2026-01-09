//! Minimal SRQL DSL parser that converts the key:value syntax into a structured AST.

use crate::{
    error::{Result, ServiceError},
    time::{parse_time_value, TimeFilterSpec},
};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Entity {
    Agents,
    Devices,
    DeviceUpdates,
    Interfaces,
    DeviceGraph,
    GraphCypher,
    Events,
    Logs,
    Services,
    Gateways,
    OtelMetrics,
    RperfMetrics,
    CpuMetrics,
    MemoryMetrics,
    DiskMetrics,
    ProcessMetrics,
    TimeseriesMetrics,
    SnmpMetrics,
    TraceSummaries,
    Traces,
}

#[derive(Debug, Clone, Serialize)]
pub struct QueryAst {
    pub entity: Entity,
    pub filters: Vec<Filter>,
    pub order: Vec<OrderClause>,
    pub limit: Option<i64>,
    pub time_filter: Option<TimeFilterSpec>,
    pub stats: Option<StatsSpec>,
    pub downsample: Option<DownsampleSpec>,
    /// Rollup stats type for querying pre-computed CAGGs (e.g., "severity", "summary", "availability")
    pub rollup_stats: Option<String>,
}

/// Parsed stats specification with structured aggregation info
#[derive(Debug, Clone, Serialize)]
pub struct StatsSpec {
    /// The raw stats expression (for backwards compatibility)
    pub raw: String,
    /// Parsed aggregations
    pub aggregations: Vec<StatsAggregation>,
}

impl StatsSpec {
    /// Returns the raw stats expression string for backwards compatibility
    /// with existing query modules that parse stats themselves.
    pub fn as_raw(&self) -> &str {
        &self.raw
    }

    /// Create a StatsSpec from a raw expression string.
    /// This is useful for creating test fixtures.
    pub fn from_raw(raw: &str) -> Self {
        parse_stats_expr(raw)
    }
}

/// A single stats aggregation like count(), sum(field), etc.
#[derive(Debug, Clone, Serialize)]
pub struct StatsAggregation {
    /// The aggregation function type
    #[serde(rename = "type")]
    pub agg_type: StatsAggType,
    /// The field to aggregate (None for count())
    pub field: Option<String>,
    /// The alias for the result
    pub alias: String,
}

/// Stats aggregation function types
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StatsAggType {
    Count,
    Sum,
    Avg,
    Min,
    Max,
}

const MAX_STATS_EXPR_LEN: usize = 1024;
const MAX_FILTER_LIST_VALUES: usize = 200;
const MAX_DOWNSAMPLE_BUCKET_SECS: i64 = 31 * 24 * 60 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DownsampleAgg {
    Avg,
    Min,
    Max,
    Sum,
    Count,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DownsampleSpec {
    pub bucket_seconds: i64,
    pub agg: DownsampleAgg,
    pub series: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Filter {
    pub field: String,
    pub op: FilterOp,
    pub value: FilterValue,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FilterOp {
    Eq,
    NotEq,
    Like,
    NotLike,
    In,
    NotIn,
    Gt,
    Gte,
    Lt,
    Lte,
}

#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum FilterValue {
    Scalar(String),
    List(Vec<String>),
}

impl FilterValue {
    pub fn as_scalar(&self) -> Result<&str> {
        match self {
            FilterValue::Scalar(v) => Ok(v.as_str()),
            FilterValue::List(_) => {
                Err(ServiceError::InvalidRequest("expected scalar value".into()))
            }
        }
    }

    pub fn as_list(&self) -> Result<&[String]> {
        match self {
            FilterValue::List(items) => Ok(items.as_slice()),
            FilterValue::Scalar(_) => {
                Err(ServiceError::InvalidRequest("expected list value".into()))
            }
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct OrderClause {
    pub field: String,
    pub direction: OrderDirection,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderDirection {
    Asc,
    Desc,
}

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
    let mut rollup_stats: Option<String> = None;

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
                time_filter = Some(parse_time_value(value.as_scalar()?)?);
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
            "stats" => {
                let mut expr = value.as_scalar()?.to_string();

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

                if expr.trim().len() > MAX_STATS_EXPR_LEN {
                    return Err(ServiceError::InvalidRequest(format!(
                        "stats expression must be <= {MAX_STATS_EXPR_LEN} characters"
                    )));
                }
                stats = Some(parse_stats_expr(&expr));
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
            "window" | "bounded" | "mode" => {
                // Aggregations and streaming hints are ignored for now.
                continue;
            }
            _ => {
                if let FilterValue::List(ref items) = value {
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
    })
}

fn parse_entity(raw: &str) -> Result<Entity> {
    let normalized = raw.trim_matches('"').trim_matches('\'').to_lowercase();
    match normalized.as_str() {
        "agents" | "agent" | "ocsf_agents" => Ok(Entity::Agents),
        "devices" | "device" | "device_inventory" => Ok(Entity::Devices),
        "device_graph" | "devicegraph" | "graph" => Ok(Entity::DeviceGraph),
        "graph_cypher" | "graphcypher" | "cypher" => Ok(Entity::GraphCypher),
        "device_updates" | "device_update" | "updates" => Ok(Entity::DeviceUpdates),
        "interfaces" | "interface" | "discovered_interfaces" => Ok(Entity::Interfaces),
        "events" | "activity" => Ok(Entity::Events),
        "logs" => Ok(Entity::Logs),
        "services" | "service" => Ok(Entity::Services),
        "gateways" | "gateway" => Ok(Entity::Gateways),
        "otel_metrics" | "metrics" => Ok(Entity::OtelMetrics),
        "rperf_metrics" | "rperf" => Ok(Entity::RperfMetrics),
        "cpu_metrics" | "cpu" => Ok(Entity::CpuMetrics),
        "memory_metrics" | "memory" => Ok(Entity::MemoryMetrics),
        "disk_metrics" | "disk" => Ok(Entity::DiskMetrics),
        "process_metrics" | "processes" => Ok(Entity::ProcessMetrics),
        "timeseries_metrics" | "timeseries" => Ok(Entity::TimeseriesMetrics),
        "snmp_metrics" | "snmp" => Ok(Entity::SnmpMetrics),
        "otel_trace_summaries" | "trace_summaries" | "traces_summaries" => {
            Ok(Entity::TraceSummaries)
        }
        "otel_traces" | "traces" | "trace_spans" => Ok(Entity::Traces),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported entity '{other}'"
        ))),
    }
}

fn parse_bucket_seconds(raw: &str) -> Result<i64> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "bucket requires a duration like 5m, 1h".into(),
        ));
    }

    let raw = raw.to_lowercase();
    let (number_part, unit_part) = raw.split_at(raw.len().saturating_sub(1));
    let value = number_part
        .parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest("bucket duration must be an integer".into()))?;

    if value <= 0 {
        return Err(ServiceError::InvalidRequest(
            "bucket duration must be positive".into(),
        ));
    }

    let multiplier = match unit_part {
        "s" => 1,
        "m" => 60,
        "h" => 60 * 60,
        "d" => 24 * 60 * 60,
        _ => {
            return Err(ServiceError::InvalidRequest(
                "bucket supports only s|m|h|d suffixes".into(),
            ))
        }
    };

    let seconds = value.saturating_mul(multiplier);
    if seconds <= 0 || seconds > MAX_DOWNSAMPLE_BUCKET_SECS {
        return Err(ServiceError::InvalidRequest(format!(
            "bucket duration must be between 1s and {}d",
            MAX_DOWNSAMPLE_BUCKET_SECS / (24 * 60 * 60)
        )));
    }
    Ok(seconds)
}

fn parse_downsample_agg(raw: &str) -> Result<DownsampleAgg> {
    match raw.trim().to_lowercase().as_str() {
        "avg" | "mean" => Ok(DownsampleAgg::Avg),
        "min" => Ok(DownsampleAgg::Min),
        "max" => Ok(DownsampleAgg::Max),
        "sum" => Ok(DownsampleAgg::Sum),
        "count" => Ok(DownsampleAgg::Count),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported agg '{other}' (use avg|min|max|sum|count)"
        ))),
    }
}

fn normalize_optional_string(raw: &str) -> Option<String> {
    let value = raw.trim().trim_matches('"').trim_matches('\'').trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

/// Parse a stats expression like "count() as total" or "sum(field) as total, avg(field) as average"
fn parse_stats_expr(raw: &str) -> StatsSpec {
    let raw = raw.trim().trim_matches('"').trim_matches('\'');
    let aggregations = raw
        .split(',')
        .filter_map(|part| parse_single_stats_agg(part.trim()))
        .collect();

    StatsSpec {
        raw: raw.to_string(),
        aggregations,
    }
}

/// Parse a single stats aggregation like "count() as total" or "sum(field) as total"
fn parse_single_stats_agg(expr: &str) -> Option<StatsAggregation> {
    let expr = expr.trim().to_lowercase();

    // Pattern: func() as alias or func(field) as alias
    // Split on " as " to get function part and alias
    let (func_part, alias) = if let Some(idx) = expr.find(" as ") {
        let (f, a) = expr.split_at(idx);
        (f.trim(), a[4..].trim()) // Skip " as "
    } else {
        // No alias, use the function name as alias
        return None; // Require alias for structured parsing
    };

    if alias.is_empty() {
        return None;
    }

    // Parse the function: count(), sum(field), avg(field), min(field), max(field)
    if let Some(inner) = func_part.strip_prefix("count(").and_then(|s| s.strip_suffix(')')) {
        // count() or count(field) - we ignore field for count
        let _ = inner; // count doesn't need a field
        return Some(StatsAggregation {
            agg_type: StatsAggType::Count,
            field: None,
            alias: alias.to_string(),
        });
    }

    if let Some(inner) = func_part.strip_prefix("sum(").and_then(|s| s.strip_suffix(')')) {
        let field = inner.trim();
        if !field.is_empty() {
            return Some(StatsAggregation {
                agg_type: StatsAggType::Sum,
                field: Some(field.to_string()),
                alias: alias.to_string(),
            });
        }
    }

    if let Some(inner) = func_part.strip_prefix("avg(").and_then(|s| s.strip_suffix(')')) {
        let field = inner.trim();
        if !field.is_empty() {
            return Some(StatsAggregation {
                agg_type: StatsAggType::Avg,
                field: Some(field.to_string()),
                alias: alias.to_string(),
            });
        }
    }

    if let Some(inner) = func_part.strip_prefix("min(").and_then(|s| s.strip_suffix(')')) {
        let field = inner.trim();
        if !field.is_empty() {
            return Some(StatsAggregation {
                agg_type: StatsAggType::Min,
                field: Some(field.to_string()),
                alias: alias.to_string(),
            });
        }
    }

    if let Some(inner) = func_part.strip_prefix("max(").and_then(|s| s.strip_suffix(')')) {
        let field = inner.trim();
        if !field.is_empty() {
            return Some(StatsAggregation {
                agg_type: StatsAggType::Max,
                field: Some(field.to_string()),
                alias: alias.to_string(),
            });
        }
    }

    None
}

fn build_filter(key: &str, value: FilterValue) -> Filter {
    let mut field = key.trim();
    let mut negated = false;
    if let Some(stripped) = field.strip_prefix('!') {
        field = stripped;
        negated = true;
    }

    let (op, final_value) = match value {
        FilterValue::Scalar(v) => {
            if let Some(stripped) = v.strip_prefix(">=") {
                (FilterOp::Gte, FilterValue::Scalar(stripped.to_string()))
            } else if let Some(stripped) = v.strip_prefix('>') {
                (FilterOp::Gt, FilterValue::Scalar(stripped.to_string()))
            } else if let Some(stripped) = v.strip_prefix("<=") {
                (FilterOp::Lte, FilterValue::Scalar(stripped.to_string()))
            } else if let Some(stripped) = v.strip_prefix('<') {
                (FilterOp::Lt, FilterValue::Scalar(stripped.to_string()))
            } else if v.contains('%') {
                if negated {
                    (FilterOp::NotLike, FilterValue::Scalar(v))
                } else {
                    (FilterOp::Like, FilterValue::Scalar(v))
                }
            } else if negated {
                (FilterOp::NotEq, FilterValue::Scalar(v))
            } else {
                (FilterOp::Eq, FilterValue::Scalar(v))
            }
        }
        FilterValue::List(_) => {
            if negated {
                (FilterOp::NotIn, value)
            } else {
                (FilterOp::In, value)
            }
        }
    };

    Filter {
        field: field.to_lowercase(),
        op,
        value: final_value,
    }
}

fn parse_order(raw: &str) -> Vec<OrderClause> {
    raw.split(',')
        .filter_map(|segment| {
            let trimmed = segment.trim();
            if trimmed.is_empty() {
                return None;
            }

            let mut parts = trimmed.splitn(3, ':');
            let field = parts.next()?.trim().to_lowercase();
            let direction = parts
                .next()
                .map(|dir| match dir.to_lowercase().as_str() {
                    "asc" => OrderDirection::Asc,
                    "desc" => OrderDirection::Desc,
                    _ => OrderDirection::Desc,
                })
                .unwrap_or(OrderDirection::Desc);

            Some(OrderClause { field, direction })
        })
        .collect()
}

fn tokenize(input: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut depth = 0usize;
    let mut escape = false;

    for ch in input.chars() {
        if escape {
            current.push(ch);
            escape = false;
            continue;
        }

        if let Some(q) = quote {
            if ch == '\\' {
                escape = true;
                continue;
            }
            if ch == q {
                quote = None;
            }
            current.push(ch);
            continue;
        }

        match ch {
            '"' | '\'' | '`' => {
                quote = Some(ch);
                current.push(ch);
            }
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth = depth.saturating_sub(1);
                current.push(ch);
            }
            c if c.is_whitespace() && depth == 0 => {
                if !current.trim().is_empty() {
                    tokens.push(current.trim().to_string());
                }
                current.clear();
            }
            _ => current.push(ch),
        }
    }

    if !current.trim().is_empty() {
        tokens.push(current.trim().to_string());
    }

    tokens
}

fn split_token(token: &str) -> Result<(&str, &str)> {
    let mut parts = token.splitn(2, ':');
    let key = parts
        .next()
        .ok_or_else(|| ServiceError::InvalidRequest("invalid token".into()))?;
    let value = parts
        .next()
        .ok_or_else(|| ServiceError::InvalidRequest("missing ':' in token".into()))?;
    Ok((key, value))
}

fn parse_value(raw: &str) -> FilterValue {
    let trimmed = raw.trim();
    if trimmed.starts_with('(') && trimmed.ends_with(')') {
        let inner = &trimmed[1..trimmed.len().saturating_sub(1)];
        let values = split_list(inner)
            .into_iter()
            .map(|item| item.trim().trim_matches('"').trim_matches('\'').to_string())
            .filter(|item| !item.is_empty())
            .collect::<Vec<_>>();
        FilterValue::List(values)
    } else {
        FilterValue::Scalar(trimmed.trim_matches('"').trim_matches('\'').to_string())
    }
}

fn split_list(value: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut depth = 0usize;
    let mut escape = false;

    for ch in value.chars() {
        if escape {
            current.push(ch);
            escape = false;
            continue;
        }

        if let Some(q) = quote {
            if ch == '\\' {
                escape = true;
                continue;
            }
            if ch == q {
                quote = None;
            }
            current.push(ch);
            continue;
        }

        match ch {
            '"' | '\'' | '`' => {
                quote = Some(ch);
                current.push(ch);
            }
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth = depth.saturating_sub(1);
                current.push(ch);
            }
            ',' if depth == 0 => {
                items.push(current.trim().to_string());
                current.clear();
            }
            _ => current.push(ch),
        }
    }

    if !current.trim().is_empty() {
        items.push(current.trim().to_string());
    }

    items
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ServiceError;

    #[test]
    fn parses_basic_query() {
        let ast = parse("in:devices hostname:%cam% limit:50 sort:last_seen:desc").unwrap();
        assert_eq!(ast.limit, Some(50));
        assert_eq!(ast.order.len(), 1);
        assert_eq!(ast.filters.len(), 1);
        assert!(matches!(ast.entity, Entity::Devices));
        assert!(matches!(ast.filters[0].op, FilterOp::Like));
    }

    #[test]
    fn parses_lists() {
        let ast = parse("in:devices discovery_sources:(sweep,armis)").unwrap();
        assert_eq!(ast.filters.len(), 1);
        assert!(matches!(ast.filters[0].value, FilterValue::List(_)));
    }

    #[test]
    fn parses_time() {
        let ast = parse("in:devices time:last_7d").unwrap();
        assert!(ast.time_filter.is_some());
    }

    #[test]
    fn parses_device_graph_entity() {
        let ast = parse("in:device_graph device_id:sr:device-1").unwrap();
        assert!(matches!(ast.entity, Entity::DeviceGraph));
    }

    #[test]
    fn parses_list_values() {
        let ast = parse("in:devices discovery_sources:(sweep,armis)").unwrap();
        assert_eq!(ast.filters.len(), 1);
        match &ast.filters[0].value {
            FilterValue::List(items) => {
                assert_eq!(items.len(), 2);
                assert_eq!(items[0], "sweep");
                assert_eq!(items[1], "armis");
            }
            _ => panic!("expected list value"),
        }
    }

    #[test]
    fn parses_stats_expression() {
        let ast = parse("in:logs stats:\"count() as total\" time:last_24h").unwrap();
        let stats = ast.stats.as_ref().unwrap();
        assert_eq!(stats.raw, "count() as total");
        assert_eq!(stats.aggregations.len(), 1);
        assert!(matches!(stats.aggregations[0].agg_type, StatsAggType::Count));
        assert_eq!(stats.aggregations[0].alias, "total");
    }

    #[test]
    fn parses_unquoted_stats_alias() {
        let ast = parse("in:devices stats:count() as total").unwrap();
        let stats = ast.stats.as_ref().unwrap();
        assert_eq!(stats.raw, "count() as total");
        assert_eq!(stats.aggregations.len(), 1);
        assert!(matches!(stats.aggregations[0].agg_type, StatsAggType::Count));
    }

    #[test]
    fn parses_unquoted_stats_alias_with_following_tokens() {
        let ast = parse("in:devices stats:count() as total time:last_7d").unwrap();
        let stats = ast.stats.as_ref().unwrap();
        assert_eq!(stats.raw, "count() as total");
        assert!(ast.time_filter.is_some());
    }

    #[test]
    fn parses_stats_with_field() {
        let ast = parse("in:devices stats:\"sum(value) as total_value\"").unwrap();
        let stats = ast.stats.as_ref().unwrap();
        assert_eq!(stats.aggregations.len(), 1);
        assert!(matches!(stats.aggregations[0].agg_type, StatsAggType::Sum));
        assert_eq!(stats.aggregations[0].field.as_deref(), Some("value"));
        assert_eq!(stats.aggregations[0].alias, "total_value");
    }

    #[test]
    fn parses_multiple_stats() {
        let ast = parse("in:devices stats:\"count() as total, sum(value) as sum_val\"").unwrap();
        let stats = ast.stats.as_ref().unwrap();
        assert_eq!(stats.aggregations.len(), 2);
        assert!(matches!(stats.aggregations[0].agg_type, StatsAggType::Count));
        assert!(matches!(stats.aggregations[1].agg_type, StatsAggType::Sum));
    }

    #[test]
    fn rejects_stats_alias_missing_identifier() {
        let err = parse("in:devices stats:count() as").unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn parses_interfaces_entity() {
        let ast = parse("in:interfaces time:last_24h").unwrap();
        assert!(matches!(ast.entity, Entity::Interfaces));
    }

    #[test]
    fn rejects_overly_long_stats_expression() {
        let query = format!("in:logs stats:{}", "x".repeat(MAX_STATS_EXPR_LEN + 1));
        let err = parse(&query).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn rejects_list_filters_over_limit() {
        let values = (0..=MAX_FILTER_LIST_VALUES)
            .map(|i| format!("value{i}"))
            .collect::<Vec<_>>()
            .join(",");
        let query = format!("in:logs service:({values})");
        let err = parse(&query).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn parses_rollup_stats_keyword() {
        let ast = parse("in:logs time:last_24h rollup_stats:severity").unwrap();
        assert!(matches!(ast.entity, Entity::Logs));
        assert_eq!(ast.rollup_stats.as_deref(), Some("severity"));
        assert!(ast.time_filter.is_some());
    }

    #[test]
    fn parses_rollup_stats_with_filters() {
        let ast = parse("in:logs service_name:core time:last_24h rollup_stats:severity").unwrap();
        assert_eq!(ast.rollup_stats.as_deref(), Some("severity"));
        assert_eq!(ast.filters.len(), 1);
        assert_eq!(ast.filters[0].field, "service_name");
    }

    #[test]
    fn rejects_empty_rollup_stats() {
        let err = parse("in:logs rollup_stats:").unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
