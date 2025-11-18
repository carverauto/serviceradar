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

mod cpu_metrics;
mod devices;
mod disk_metrics;
mod events;
mod interfaces;
mod logs;
mod memory_metrics;
mod otel_metrics;
mod pollers;
mod rperf_metrics;
mod services;
mod trace_summaries;
mod traces;

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

        let results = match plan.entity {
            Entity::Devices => devices::execute(&mut conn, &plan).await?,
            Entity::Events => events::execute(&mut conn, &plan).await?,
            Entity::Interfaces => interfaces::execute(&mut conn, &plan).await?,
            Entity::Logs => logs::execute(&mut conn, &plan).await?,
            Entity::Pollers => pollers::execute(&mut conn, &plan).await?,
            Entity::OtelMetrics => otel_metrics::execute(&mut conn, &plan).await?,
            Entity::RperfMetrics => rperf_metrics::execute(&mut conn, &plan).await?,
            Entity::CpuMetrics => cpu_metrics::execute(&mut conn, &plan).await?,
            Entity::MemoryMetrics => memory_metrics::execute(&mut conn, &plan).await?,
            Entity::DiskMetrics => disk_metrics::execute(&mut conn, &plan).await?,
            Entity::Services => services::execute(&mut conn, &plan).await?,
            Entity::TraceSummaries => trace_summaries::execute(&mut conn, &plan).await?,
            Entity::Traces => traces::execute(&mut conn, &plan).await?,
        };

        let pagination = self.build_pagination(&plan, results.len() as i64);
        Ok(QueryResponse {
            results,
            pagination,
            error: None,
        })
    }

    pub async fn translate(&self, request: TranslateRequest) -> Result<TranslateResponse> {
        let ast = parser::parse(&request.query)?;
        let synthetic = QueryRequest {
            query: request.query.clone(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };
        let plan = build_query_plan(&self.config, &synthetic, ast)?;

        let sql = match plan.entity {
            Entity::Devices => devices::to_debug_sql(&plan)?,
            Entity::Events => events::to_debug_sql(&plan)?,
            Entity::Interfaces => interfaces::to_debug_sql(&plan)?,
            Entity::Logs => logs::to_debug_sql(&plan)?,
            Entity::Pollers => pollers::to_debug_sql(&plan)?,
            Entity::OtelMetrics => otel_metrics::to_debug_sql(&plan)?,
            Entity::RperfMetrics => rperf_metrics::to_debug_sql(&plan)?,
            Entity::CpuMetrics => cpu_metrics::to_debug_sql(&plan)?,
            Entity::MemoryMetrics => memory_metrics::to_debug_sql(&plan)?,
            Entity::DiskMetrics => disk_metrics::to_debug_sql(&plan)?,
            Entity::Services => services::to_debug_sql(&plan)?,
            Entity::TraceSummaries => trace_summaries::to_debug_sql(&plan)?,
            Entity::Traces => traces::to_debug_sql(&plan)?,
        };

        Ok(TranslateResponse {
            sql,
            params: Vec::new(),
        })
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

    Ok(QueryPlan {
        entity: ast.entity,
        filters: ast.filters,
        order: ast.order,
        limit,
        offset,
        time_range,
        stats: ast.stats,
    })
}

fn determine_limit(config: &AppConfig, candidate: Option<i64>) -> i64 {
    let default = config.default_limit;
    let max = config.max_limit;
    candidate.unwrap_or(default).clamp(1, max)
}

#[cfg(test)]
mod tests {
    use super::{devices, interfaces, pollers, *};
    use crate::parser::{self, FilterOp, FilterValue, OrderDirection};
    use chrono::Duration as ChronoDuration;
    use std::time::Duration as StdDuration;

    #[test]
    fn devices_docs_example_available_true() {
        let query =
            "in:devices time:last_7d sort:last_seen:desc limit:20 is_available:true";
        let plan = plan_for(query);

        assert!(matches!(plan.entity, Entity::Devices));
        assert_eq!(plan.limit, 20);
        assert_eq!(plan.offset, 0);
        assert!(plan.time_range.is_some());
        assert_eq!(plan.order.len(), 1);
        assert_eq!(plan.order[0].field, "last_seen");
        assert!(matches!(plan.order[0].direction, OrderDirection::Desc));
        assert!(has_availability_filter(&plan, true));

        let sql = devices::to_debug_sql(&plan).expect("should build SQL for docs query");
        assert!(
            sql.to_lowercase()
                .contains("\"unified_devices\".\"is_available\" = $3"),
            "expected SQL to include availability predicate, got: {sql}"
        );
    }

    #[test]
    fn devices_docs_example_available_false() {
        let query =
            "in:devices time:last_7d sort:last_seen:desc limit:20 is_available:false";
        let plan = plan_for(query);

        assert!(matches!(plan.entity, Entity::Devices));
        assert_eq!(plan.limit, 20);
        assert!(plan.time_range.is_some());
        assert!(has_availability_filter(&plan, false));

        let sql = devices::to_debug_sql(&plan).expect("should build SQL for docs query");
        assert!(
            sql.to_lowercase()
                .contains("\"unified_devices\".\"is_available\" = $3"),
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
        assert_eq!(discovery_filters.len(), 2, "expected repeated discovery_sources filters");
        let seen_values = discovery_filters
            .iter()
            .map(|filter| match &filter.value {
                FilterValue::List(items) => items.clone(),
                _ => panic!("discovery_sources filters should be list-valued"),
            })
            .collect::<Vec<_>>();
        assert!(seen_values.iter().any(|values| values == &vec!["sweep".to_string()]));
        assert!(seen_values.iter().any(|values| values == &vec!["armis".to_string()]));
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
        let sql = interfaces::to_debug_sql(&plan).expect("should build interfaces SQL");
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
        let sql = pollers::to_debug_sql(&plan).expect("should build pollers SQL");
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
    pub params: Vec<String>,
}
