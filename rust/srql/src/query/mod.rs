macro_rules! apply_text_filter {
    ($query:expr, $filter:expr, $column:expr) => {{
        let __next = match $filter.op {
            crate::parser::FilterOp::Eq => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.eq(value))
            }
            crate::parser::FilterOp::NotEq => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.ne(value))
            }
            crate::parser::FilterOp::Like => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.ilike(value))
            }
            crate::parser::FilterOp::NotLike => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.not_ilike(value))
            }
            crate::parser::FilterOp::In => {
                let values = $filter.value.as_list()?.to_vec();
                if values.is_empty() {
                    $query
                } else {
                    $query.filter($column.eq_any(values))
                }
            }
            crate::parser::FilterOp::NotIn => {
                let values = $filter.value.as_list()?.to_vec();
                if values.is_empty() {
                    $query
                } else {
                    $query.filter($column.ne_all(values))
                }
            }
            _ => {
                return Err(crate::error::ServiceError::InvalidRequest(format!(
                    "unsupported operator for text filter: {:?}",
                    $filter.op
                )));
            }
        };
        Ok::<_, crate::error::ServiceError>(__next)
    }};
}

macro_rules! apply_text_filter_no_lists {
    ($query:expr, $filter:expr, $column:expr, $error:expr) => {{
        let __next = match $filter.op {
            crate::parser::FilterOp::Eq => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.eq(value))
            }
            crate::parser::FilterOp::NotEq => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.ne(value))
            }
            crate::parser::FilterOp::Like => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.ilike(value))
            }
            crate::parser::FilterOp::NotLike => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.not_ilike(value))
            }
            crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
                return Err(crate::error::ServiceError::InvalidRequest($error.into()));
            }
            _ => {
                return Err(crate::error::ServiceError::InvalidRequest(format!(
                    "unsupported operator for text filter: {:?}",
                    $filter.op
                )));
            }
        };
        Ok::<_, crate::error::ServiceError>(__next)
    }};
}

macro_rules! apply_eq_filter {
    ($query:expr, $filter:expr, $column:expr, $value:expr, $error:expr) => {{
        let __value = $value;
        let __next = match $filter.op {
            crate::parser::FilterOp::Eq => $query.filter($column.eq(__value.clone())),
            crate::parser::FilterOp::NotEq => $query.filter($column.ne(__value)),
            _ => {
                return Err(crate::error::ServiceError::InvalidRequest($error.into()));
            }
        };
        Ok::<_, crate::error::ServiceError>(__next)
    }};
}

mod agents;
mod cpu_metrics;
mod device_graph;
mod device_updates;
mod devices;
mod disk_metrics;
mod downsample;
mod events;
mod graph_cypher;
mod interfaces;
mod logs;
mod memory_metrics;
mod otel_metrics;
mod pollers;
mod process_metrics;
mod services;
mod timeseries_metrics;
mod trace_summaries;
mod traces;
mod viz;

use crate::{
    config::AppConfig,
    db::PgPool,
    error::{Result, ServiceError},
    pagination::{decode_cursor, encode_cursor},
    parser::{self, Entity, Filter, OrderClause, QueryAst},
    time::TimeRange,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Arc;
use tracing::error;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "t", content = "v", rename_all = "snake_case")]
pub enum BindParam {
    Text(String),
    TextArray(Vec<String>),
    IntArray(Vec<i64>),
    Bool(bool),
    Int(i64),
    Float(f64),
    Timestamptz(String),
}

impl BindParam {
    fn timestamptz(value: chrono::DateTime<Utc>) -> Self {
        Self::Timestamptz(value.to_rfc3339())
    }
}

#[derive(Clone)]
pub struct QueryEngine {
    pool: PgPool,
    config: Arc<AppConfig>,
}

impl QueryEngine {
    pub fn new(pool: PgPool, config: Arc<AppConfig>) -> Self {
        Self { pool, config }
    }

    pub fn config(&self) -> &AppConfig {
        &self.config
    }

    pub async fn execute_query(&self, request: QueryRequest) -> Result<QueryResponse> {
        let ast = parser::parse(&request.query)?;
        let plan = build_query_plan(&self.config, &request, ast)?;
        let mut conn = self.pool.get().await.map_err(|err| {
            error!(error = ?err, "failed to acquire database connection");
            ServiceError::Internal(anyhow::anyhow!("{err:?}"))
        })?;

        let results = if plan.downsample.is_some() {
            downsample::execute(&mut conn, &plan).await?
        } else {
            match plan.entity {
                Entity::Agents => agents::execute(&mut conn, &plan).await?,
                Entity::Devices => devices::execute(&mut conn, &plan).await?,
                Entity::DeviceUpdates => device_updates::execute(&mut conn, &plan).await?,
                Entity::DeviceGraph => device_graph::execute(&mut conn, &plan).await?,
                Entity::GraphCypher => graph_cypher::execute(&mut conn, &plan).await?,
                Entity::Events => events::execute(&mut conn, &plan).await?,
                Entity::Interfaces => interfaces::execute(&mut conn, &plan).await?,
                Entity::Logs => logs::execute(&mut conn, &plan).await?,
                Entity::Pollers => pollers::execute(&mut conn, &plan).await?,
                Entity::OtelMetrics => otel_metrics::execute(&mut conn, &plan).await?,
                Entity::RperfMetrics | Entity::TimeseriesMetrics | Entity::SnmpMetrics => {
                    timeseries_metrics::execute(&mut conn, &plan).await?
                }
                Entity::CpuMetrics => cpu_metrics::execute(&mut conn, &plan).await?,
                Entity::MemoryMetrics => memory_metrics::execute(&mut conn, &plan).await?,
                Entity::DiskMetrics => disk_metrics::execute(&mut conn, &plan).await?,
                Entity::ProcessMetrics => process_metrics::execute(&mut conn, &plan).await?,
                Entity::Services => services::execute(&mut conn, &plan).await?,
                Entity::TraceSummaries => trace_summaries::execute(&mut conn, &plan).await?,
                Entity::Traces => traces::execute(&mut conn, &plan).await?,
            }
        };

        let pagination = self.build_pagination(&plan, results.len() as i64);
        Ok(QueryResponse {
            results,
            pagination,
            error: None,
        })
    }

    pub async fn translate(&self, request: TranslateRequest) -> Result<TranslateResponse> {
        translate_request(self.config(), QueryRequest::from(request))
    }

    fn build_pagination(&self, plan: &QueryPlan, fetched: i64) -> PaginationMeta {
        let next_cursor = if fetched >= plan.limit {
            Some(encode_cursor(plan.offset.saturating_add(plan.limit)))
        } else {
            None
        };

        let prev_cursor = if plan.offset > 0 {
            let prev = plan.offset.saturating_sub(plan.limit);
            Some(encode_cursor(prev))
        } else {
            None
        };

        PaginationMeta {
            next_cursor,
            prev_cursor,
            limit: Some(plan.limit),
        }
    }
}

fn build_query_plan(
    config: &AppConfig,
    request: &QueryRequest,
    ast: QueryAst,
) -> Result<QueryPlan> {
    let limit = determine_limit(config, request.limit.or(ast.limit));
    let offset = request
        .cursor
        .as_deref()
        .map(decode_cursor)
        .transpose()?
        .unwrap_or(0)
        .max(0);
    let time_range = ast
        .time_filter
        .map(|spec| spec.resolve(Utc::now()))
        .transpose()?;

    let (filters, order, downsample) =
        normalize_device_aliases(&ast.entity, ast.filters, ast.order, ast.downsample);

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
    })
}

fn determine_limit(config: &AppConfig, candidate: Option<i64>) -> i64 {
    let default = config.default_limit;
    let max = config.max_limit;
    candidate.unwrap_or(default).clamp(1, max)
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
        if let Some(series) = spec.series.as_mut() {
            if let Some(mapped) = normalize_device_field(entity, series) {
                *series = mapped;
            }
        }
        spec
    });

    (filters, order, downsample)
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

pub(super) fn max_dollar_placeholder(sql: &str) -> usize {
    let bytes = sql.as_bytes();
    let mut max = 0usize;
    let mut i = 0usize;

    while i < bytes.len() {
        if bytes[i] != b'$' {
            i += 1;
            continue;
        }

        i += 1;
        if i >= bytes.len() || !bytes[i].is_ascii_digit() {
            continue;
        }

        let mut value = 0usize;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            value = value * 10 + (bytes[i] - b'0') as usize;
            i += 1;
        }

        max = max.max(value);
    }

    max
}

pub(super) fn reconcile_limit_offset_binds(
    sql: &str,
    params: &mut Vec<BindParam>,
    limit: i64,
    offset: i64,
) -> Result<()> {
    let expected = max_dollar_placeholder(sql);
    let current = params.len();
    if expected < current {
        return Err(ServiceError::Internal(anyhow::anyhow!(
            "sql expects {expected} binds but {current} were collected"
        )));
    }

    match expected.saturating_sub(current) {
        0 => Ok(()),
        1 => {
            params.push(BindParam::Int(limit));
            Ok(())
        }
        2 => {
            params.push(BindParam::Int(limit));
            params.push(BindParam::Int(offset));
            Ok(())
        }
        extra => Err(ServiceError::Internal(anyhow::anyhow!(
            "unexpected bind arity gap: {extra}"
        ))),
    }
}

pub(super) fn diesel_sql<T>(query: &T) -> Result<String>
where
    T: diesel::query_builder::QueryFragment<diesel::pg::Pg>,
{
    use diesel::query_builder::QueryBuilder as _;

    let backend = diesel::pg::Pg;
    let mut query_builder = <diesel::pg::Pg as diesel::backend::Backend>::QueryBuilder::default();
    diesel::query_builder::QueryFragment::<diesel::pg::Pg>::to_sql(
        query,
        &mut query_builder,
        &backend,
    )
    .map_err(|err| {
        error!(error = ?err, "failed to serialize diesel SQL");
        ServiceError::Internal(anyhow::anyhow!("failed to serialize SQL"))
    })?;

    Ok(query_builder.finish())
}

#[cfg(any(test, debug_assertions))]
pub(super) fn diesel_bind_count<T>(query: &T) -> Result<usize>
where
    T: diesel::query_builder::QueryFragment<diesel::pg::Pg>,
{
    let rendered = diesel::debug_query::<diesel::pg::Pg, _>(query).to_string();
    let marker = "-- binds:";
    let binds = rendered
        .split_once(marker)
        .map(|(_, suffix)| suffix.trim())
        .ok_or_else(|| ServiceError::Internal(anyhow::anyhow!("missing binds marker")))?;

    count_debug_binds_list(binds).ok_or_else(|| {
        ServiceError::Internal(anyhow::anyhow!("failed to parse diesel debug bind list"))
    })
}

#[cfg(any(test, debug_assertions))]
fn count_debug_binds_list(binds: &str) -> Option<usize> {
    let bytes = binds.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }

    if i >= bytes.len() || bytes[i] != b'[' {
        return None;
    }

    let mut bracket_depth = 0i32;
    let mut paren_depth = 0i32;
    let mut brace_depth = 0i32;
    let mut in_string = false;
    let mut escape = false;
    let mut in_item = false;
    let mut count = 0usize;

    for &b in bytes[i..].iter() {
        if in_string {
            if escape {
                escape = false;
                continue;
            }

            if b == b'\\' {
                escape = true;
                continue;
            }

            if b == b'"' {
                in_string = false;
            }

            continue;
        }

        match b {
            b'"' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                in_string = true;
            }
            b'[' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                bracket_depth += 1;
                if bracket_depth == 1 {
                    in_item = false;
                }
            }
            b']' => {
                if bracket_depth == 1 && in_item {
                    count += 1;
                    in_item = false;
                }
                bracket_depth -= 1;
                if bracket_depth <= 0 {
                    break;
                }
            }
            b'{' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                brace_depth += 1
            }
            b'}' => brace_depth -= 1,
            b'(' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                paren_depth += 1
            }
            b')' => paren_depth -= 1,
            b',' => {
                if bracket_depth == 1 && brace_depth == 0 && paren_depth == 0 && in_item {
                    count += 1;
                    in_item = false;
                }
            }
            b if b.is_ascii_whitespace() => {}
            _ => {
                if bracket_depth == 1 && !in_item {
                    in_item = true;
                }
            }
        }
    }

    Some(count)
}

pub fn translate_request(config: &AppConfig, request: QueryRequest) -> Result<TranslateResponse> {
    let ast = parser::parse(&request.query)?;
    let plan = build_query_plan(config, &request, ast)?;
    let viz = viz::meta_for_plan(&plan);

    let (sql, params) = if plan.downsample.is_some() {
        downsample::to_sql_and_params(&plan)?
    } else {
        match plan.entity {
            Entity::Agents => agents::to_sql_and_params(&plan)?,
            Entity::Devices => devices::to_sql_and_params(&plan)?,
            Entity::DeviceUpdates => device_updates::to_sql_and_params(&plan)?,
            Entity::DeviceGraph => device_graph::to_sql_and_params(&plan)?,
            Entity::GraphCypher => graph_cypher::to_sql_and_params(&plan)?,
            Entity::Events => events::to_sql_and_params(&plan)?,
            Entity::Interfaces => interfaces::to_sql_and_params(&plan)?,
            Entity::Logs => logs::to_sql_and_params(&plan)?,
            Entity::Pollers => pollers::to_sql_and_params(&plan)?,
            Entity::OtelMetrics => otel_metrics::to_sql_and_params(&plan)?,
            Entity::RperfMetrics | Entity::TimeseriesMetrics | Entity::SnmpMetrics => {
                timeseries_metrics::to_sql_and_params(&plan)?
            }
            Entity::CpuMetrics => cpu_metrics::to_sql_and_params(&plan)?,
            Entity::MemoryMetrics => memory_metrics::to_sql_and_params(&plan)?,
            Entity::DiskMetrics => disk_metrics::to_sql_and_params(&plan)?,
            Entity::ProcessMetrics => process_metrics::to_sql_and_params(&plan)?,
            Entity::Services => services::to_sql_and_params(&plan)?,
            Entity::TraceSummaries => trace_summaries::to_sql_and_params(&plan)?,
            Entity::Traces => traces::to_sql_and_params(&plan)?,
        }
    };

    let next_cursor = Some(encode_cursor(plan.offset.saturating_add(plan.limit)));
    let prev_cursor = if plan.offset > 0 {
        Some(encode_cursor(plan.offset.saturating_sub(plan.limit)))
    } else {
        None
    };

    Ok(TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor,
            prev_cursor,
            limit: Some(plan.limit),
        },
        viz,
    })
}

#[cfg(test)]
mod tests {
    use super::{devices, interfaces, pollers, *};
    use crate::parser::{self, FilterOp, FilterValue, OrderDirection};
    use chrono::Duration as ChronoDuration;
    use std::time::Duration as StdDuration;

    #[test]
    fn devices_docs_example_available_true() {
        let query = "in:devices time:last_7d sort:last_seen:desc limit:20 is_available:true";
        let plan = plan_for(query);

        assert!(matches!(plan.entity, Entity::Devices));
        assert_eq!(plan.limit, 20);
        assert_eq!(plan.offset, 0);
        assert!(plan.time_range.is_some());
        assert_eq!(plan.order.len(), 1);
        assert_eq!(plan.order[0].field, "last_seen");
        assert!(matches!(plan.order[0].direction, OrderDirection::Desc));
        assert!(has_availability_filter(&plan, true));

        let (sql, _) = devices::to_sql_and_params(&plan).expect("should build SQL for docs query");
        assert!(
            sql.to_lowercase()
                .contains("\"ocsf_devices\".\"is_available\" = $3"),
            "expected SQL to include availability predicate, got: {sql}"
        );
    }

    #[test]
    fn devices_docs_example_available_false() {
        let query = "in:devices time:last_7d sort:last_seen:desc limit:20 is_available:false";
        let plan = plan_for(query);

        assert!(matches!(plan.entity, Entity::Devices));
        assert_eq!(plan.limit, 20);
        assert!(plan.time_range.is_some());
        assert!(has_availability_filter(&plan, false));

        let (sql, _) = devices::to_sql_and_params(&plan).expect("should build SQL for docs query");
        assert!(
            sql.to_lowercase()
                .contains("\"ocsf_devices\".\"is_available\" = $3"),
            "expected SQL to include availability predicate, got: {sql}"
        );
    }

    #[test]
    fn devices_docs_example_discovery_sources_contains_all() {
        let query = "in:devices discovery_sources:(sweep) discovery_sources:(armis) time:last_7d sort:last_seen:desc";
        let plan = plan_for(query);

        assert!(matches!(plan.entity, Entity::Devices));
        assert_eq!(plan.order[0].field, "last_seen");
        let range = plan
            .time_range
            .expect("docs example includes explicit time window");
        let span = range.end.signed_duration_since(range.start);
        assert_eq!(span, ChronoDuration::days(7));

        let discovery_filters: Vec<_> = plan
            .filters
            .iter()
            .filter(|filter| filter.field == "discovery_sources")
            .collect();
        assert_eq!(
            discovery_filters.len(),
            2,
            "expected repeated discovery_sources filters"
        );
        let seen_values = discovery_filters
            .iter()
            .map(|filter| match &filter.value {
                FilterValue::List(items) => items.clone(),
                _ => panic!("discovery_sources filters should be list-valued"),
            })
            .collect::<Vec<_>>();
        assert!(seen_values
            .iter()
            .any(|values| values == &vec!["sweep".to_string()]));
        assert!(seen_values
            .iter()
            .any(|values| values == &vec!["armis".to_string()]));
    }

    #[test]
    fn services_docs_example_service_type_timeframe() {
        let query =
            r#"in:services service_type:(ssh,sftp) timeFrame:"14 Days" sort:timestamp:desc"#;
        let plan = plan_for(query);

        assert!(matches!(plan.entity, Entity::Services));
        let filter = plan
            .filters
            .iter()
            .find(|filter| filter.field == "service_type")
            .expect("query must contain service_type filter");
        assert!(matches!(filter.op, FilterOp::In));
        match &filter.value {
            FilterValue::List(values) => {
                assert_eq!(values, &vec!["ssh".to_string(), "sftp".to_string()]);
            }
            _ => panic!("service_type filter must be a list"),
        }

        let range = plan
            .time_range
            .expect("timeFrame should resolve to a time range");
        let span = range.end.signed_duration_since(range.start);
        assert_eq!(span, ChronoDuration::days(14));

        assert_eq!(plan.order[0].field, "timestamp");
        assert!(matches!(plan.order[0].direction, OrderDirection::Desc));
    }

    #[test]
    fn interfaces_docs_example_ip_addresses_contains_any() {
        let query =
            "in:interfaces time:last_24h ip_addresses:(10.0.0.1,10.0.0.2) sort:timestamp:asc limit:5";
        let plan = plan_for(query);

        assert!(matches!(plan.entity, Entity::Interfaces));
        assert_eq!(plan.limit, 5);
        let (sql, _) = interfaces::to_sql_and_params(&plan).expect("should build interfaces SQL");
        let lower = sql.to_lowercase();
        assert!(
            lower.contains("coalesce(") && lower.contains("ip_addresses"),
            "expected coalesce ip_addresses containment, got: {sql}"
        );
        assert!(lower.contains("order by \"discovered_interfaces\".\"timestamp\" asc"));
    }

    #[test]
    fn pollers_docs_example_health_and_status() {
        let query = "in:pollers is_healthy:true status:ready sort:agent_count:desc limit:10";
        let plan = plan_for(query);

        assert!(matches!(plan.entity, Entity::Pollers));
        assert_eq!(plan.limit, 10);
        assert_eq!(plan.order[0].field, "agent_count");
        let (sql, _) = pollers::to_sql_and_params(&plan).expect("should build pollers SQL");
        let lower = sql.to_lowercase();
        assert!(
            lower.contains("\"pollers\".\"is_healthy\" =")
                && lower.contains("\"pollers\".\"status\" ="),
            "expected bool + status filters in SQL, got: {sql}"
        );
    }

    fn plan_for(query: &str) -> QueryPlan {
        let config = test_config();
        let ast = parser::parse(query).expect("docs query should parse");
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };
        build_query_plan(&config, &request, ast).expect("should build plan for docs query")
    }

    fn has_availability_filter(plan: &QueryPlan, expected: bool) -> bool {
        plan.filters.iter().any(|filter| {
            filter.field == "is_available"
                && matches!(
                    &filter.value,
                    FilterValue::Scalar(value) if value.eq_ignore_ascii_case(
                        if expected { "true" } else { "false" }
                    )
                )
        })
    }

    fn test_config() -> AppConfig {
        AppConfig {
            listen_addr: "127.0.0.1:0".parse().unwrap(),
            database_url: "postgres://example/db".to_string(),
            max_pool_size: 1,
            pg_ssl_root_cert: None,
            pg_ssl_cert: None,
            pg_ssl_key: None,
            api_key: None,
            api_key_kv_key: None,
            allowed_origins: None,
            default_limit: 100,
            max_limit: 500,
            request_timeout: StdDuration::from_secs(30),
            rate_limit_max_requests: 120,
            rate_limit_window: StdDuration::from_secs(60),
        }
    }

    #[test]
    fn translate_param_arity_matches_sql_placeholders() {
        let config = test_config();

        let cursor = encode_cursor(250);

        let cases = [
            QueryRequest {
                query: "in:devices stats:count() as total".to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:services available:false time:last_24h stats:count() as failing"
                    .to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:pollers is_healthy:true status:ready sort:agent_count:desc".to_string(),
                limit: Some(10),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:devices time:last_7d sort:last_seen:desc is_available:true discovery_sources:(sweep,armis)".to_string(),
                limit: Some(20),
                cursor: Some(cursor.clone()),
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:interfaces time:last_24h ip_addresses:(10.0.0.1,10.0.0.2) sort:timestamp:asc".to_string(),
                limit: Some(5),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:traces time:last_24h status_code:(1,2) kind:(1,2,3) sort:timestamp:desc".to_string(),
                limit: Some(25),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:device_graph device_id:dev-1 collector_owned_only:true include_topology:false".to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
        ];

        for request in cases {
            let response = match translate_request(&config, request.clone()) {
                Ok(response) => response,
                Err(err) => {
                    panic!("translation failed for query '{}': {err:?}", request.query)
                }
            };
            let max_placeholder = super::max_dollar_placeholder(&response.sql);
            assert_eq!(
                max_placeholder,
                response.params.len(),
                "sql placeholders must match params length\nsql: {}\nparams: {:?}",
                response.sql,
                response.params
            );
        }
    }

    #[test]
    fn translate_includes_visualization_metadata() {
        let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
        let request = QueryRequest {
            query: "in:timeseries_metrics time:last_7d limit:10".to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = translate_request(&config, request).expect("translation should succeed");
        let viz = response.viz.expect("viz metadata should be present");

        assert!(
            viz.columns.iter().any(|col| {
                col.name == "timestamp" && matches!(col.col_type, viz::ColumnType::Timestamptz)
            }),
            "expected timestamp column meta, got: {:?}",
            viz.columns
        );

        assert!(
            viz.suggestions
                .iter()
                .any(|s| matches!(s.kind, viz::VizKind::Timeseries)),
            "expected timeseries suggestion, got: {:?}",
            viz.suggestions
        );
    }

    #[test]
    fn translate_downsample_emits_time_bucket_query() {
        let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
        let request = QueryRequest {
            query:
                "in:timeseries_metrics time:last_7d bucket:5m agg:avg series:metric_name limit:25"
                    .to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = translate_request(&config, request).expect("translation should succeed");

        assert!(
            response.sql.to_lowercase().contains("time_bucket("),
            "expected time_bucket in SQL, got: {}",
            response.sql
        );
        assert!(
            response.sql.to_lowercase().contains("group by 1, 2"),
            "expected group by bucket+series, got: {}",
            response.sql
        );

        let viz = response.viz.expect("viz metadata should be present");
        assert_eq!(viz.columns.len(), 3);
        assert!(
            viz.suggestions
                .iter()
                .any(|s| matches!(s.kind, viz::VizKind::Timeseries)),
            "expected timeseries suggestion, got: {:?}",
            viz.suggestions
        );

        assert!(
            response.params.len() >= 4,
            "expected time range + limit/offset params, got: {:?}",
            response.params
        );
    }

    #[test]
    fn translate_graph_cypher_rejects_mutations() {
        let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
        let request = QueryRequest {
            query: "in:graph_cypher cypher:\"CREATE (n:Device {id:'x'}) RETURN 1 as result\""
                .to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let err = translate_request(&config, request).expect_err("should reject write cypher");
        assert!(
            err.to_string().to_lowercase().contains("read-only"),
            "expected read-only error, got: {err}"
        );
    }

    #[test]
    fn translate_graph_cypher_wraps_rows_as_topology_payload() {
        let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
        let request = QueryRequest {
            query: "in:graph_cypher cypher:\"MATCH (n) RETURN n\" limit:10".to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = translate_request(&config, request).expect("translation should succeed");
        let sql = response.sql.to_lowercase();

        assert!(
            sql.contains("jsonb_build_object('nodes'"),
            "expected topology wrapper in SQL, got: {}",
            response.sql
        );
        assert!(
            sql.contains("jsonb_build_array"),
            "expected jsonb_build_array in SQL, got: {}",
            response.sql
        );
        assert_eq!(
            response.params.len(),
            2,
            "expected limit + offset binds, got: {:?}",
            response.params
        );
    }
}

#[derive(Debug, Clone)]
pub struct QueryPlan {
    pub entity: Entity,
    pub filters: Vec<Filter>,
    pub order: Vec<OrderClause>,
    pub limit: i64,
    pub offset: i64,
    pub time_range: Option<TimeRange>,
    pub stats: Option<String>,
    pub downsample: Option<crate::parser::DownsampleSpec>,
    /// Rollup stats type for querying pre-computed CAGGs (e.g., "severity", "summary", "availability")
    pub rollup_stats: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum QueryDirection {
    #[default]
    Next,
    Prev,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct QueryRequest {
    pub query: String,
    #[serde(default)]
    pub limit: Option<i64>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub direction: QueryDirection,
    #[serde(default)]
    pub mode: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TranslateRequest {
    pub query: String,
    #[serde(default)]
    pub limit: Option<i64>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub direction: QueryDirection,
    #[serde(default)]
    pub mode: Option<String>,
}

impl From<TranslateRequest> for QueryRequest {
    fn from(request: TranslateRequest) -> Self {
        Self {
            query: request.query,
            limit: request.limit,
            cursor: request.cursor,
            direction: request.direction,
            mode: request.mode,
        }
    }
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct PaginationMeta {
    pub next_cursor: Option<String>,
    pub prev_cursor: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct QueryResponse {
    pub results: Vec<Value>,
    pub pagination: PaginationMeta,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TranslateResponse {
    pub sql: String,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub params: Vec<BindParam>,
    pub pagination: PaginationMeta,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub viz: Option<viz::VizMeta>,
}
