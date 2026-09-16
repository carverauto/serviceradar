use super::{types::BindParam, PaginationMeta, QueryPlan, QueryResponse, TranslateResponse};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, StatsAggType, StatsAggregation},
};
use chrono::{Duration as ChronoDuration, SecondsFormat, Utc};
use serde_json::Value;

const HOURLY_MV_THRESHOLD_HOURS: i64 = 6;

/// Compile an authorized SRQL plan to StarRocks SQL.
///
/// Unsupported shapes return a capability error instead of silently falling
/// back to PostgreSQL.
pub fn translate(plan: &QueryPlan) -> Result<TranslateResponse> {
    match dataset_for(&plan.entity) {
        Some(dataset) => dataset_sql(plan, dataset),
        None => Err(ServiceError::NotImplemented(format!(
            "starrocks_unsupported_entity: {:?}",
            plan.entity
        ))),
    }
}

/// Execute a compiled StarRocks plan. Missing executors and unsupported
/// entities are capability errors — never a silent PostgreSQL fallback.
pub fn execute_plan(plan: &QueryPlan, executor: Option<&dyn SqlExecutor>) -> Result<QueryResponse> {
    let compiled = translate(plan)?;
    let executor = executor
        .ok_or_else(|| ServiceError::NotImplemented("starrocks_not_configured".to_string()))?;
    let results = executor.execute_sql(&compiled.sql)?;
    Ok(QueryResponse {
        results,
        pagination: compiled.pagination,
        error: None,
    })
}

pub trait SqlExecutor: Send + Sync {
    fn execute_sql(&self, sql: &str) -> Result<Vec<Value>>;
}

pub struct HttpSqlExecutor {
    fe_http: String,
    database: String,
    user: String,
    password: String,
}

impl HttpSqlExecutor {
    pub fn from_env() -> Option<Self> {
        let fe_http = std::env::var("STARROCKS_FE_HTTP").ok()?;
        Some(Self {
            fe_http,
            database: std::env::var("STARROCKS_DATABASE")
                .unwrap_or_else(|_| "serviceradar".to_string()),
            user: std::env::var("STARROCKS_USER").unwrap_or_else(|_| "root".to_string()),
            password: std::env::var("STARROCKS_PASSWORD").unwrap_or_default(),
        })
    }

}

impl SqlExecutor for HttpSqlExecutor {
    fn execute_sql(&self, sql: &str) -> Result<Vec<Value>> {
        let url = format!(
            "{}/api/v1/catalogs/default_catalog/databases/{}/sql",
            self.fe_http.trim_end_matches('/'),
            self.database
        );
        let body = serde_json::to_vec(&serde_json::json!({ "query": sql }))
            .map_err(|err| ServiceError::Internal(anyhow::anyhow!("starrocks_http_encode: {err}")))?;
        let response = ureq::post(&url)
            .header(
                "authorization",
                format!(
                    "Basic {}",
                    base64::Engine::encode(
                        &base64::engine::general_purpose::STANDARD,
                        format!("{}:{}", self.user, self.password)
                    )
                ),
            )
            .header("content-type", "application/json")
            .send(body)
            .map_err(|err| ServiceError::Internal(anyhow::anyhow!("starrocks_http: {err}")))?;
        let text = response
            .into_body()
            .read_to_string()
            .map_err(|err| ServiceError::Internal(anyhow::anyhow!("starrocks_http_body: {err}")))?;
        let payload: Value = serde_json::from_str(&text)
            .map_err(|err| ServiceError::Internal(anyhow::anyhow!("starrocks_http_json: {err}")))?;
        Ok(rows_from_http_payload(payload))
    }
}

fn rows_from_http_payload(payload: Value) -> Vec<Value> {
    let meta = payload
        .get("meta")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let names: Vec<String> = meta
        .iter()
        .map(|col| {
            col.get("name")
                .and_then(Value::as_str)
                .unwrap_or("col")
                .to_string()
        })
        .collect();
    payload
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|row| match row {
            Value::Array(cells) => {
                let mut object = serde_json::Map::new();
                for (idx, cell) in cells.into_iter().enumerate() {
                    let key = names
                        .get(idx)
                        .cloned()
                        .unwrap_or_else(|| format!("col{idx}"));
                    object.insert(key, cell);
                }
                Value::Object(object)
            }
            other => other,
        })
        .collect()
}

#[derive(Clone, Copy)]
struct Dataset {
    raw_table: &'static str,
    hourly_table: Option<&'static str>,
    time_column: &'static str,
}

fn dataset_for(entity: &Entity) -> Option<Dataset> {
    match entity {
        Entity::Flows | Entity::AttributedFlows => Some(Dataset {
            raw_table: "serviceradar.ocsf_network_activity",
            hourly_table: Some("serviceradar.ocsf_network_activity_hourly"),
            time_column: "time",
        }),
        Entity::TimeseriesMetrics
        | Entity::SnmpMetrics
        | Entity::RperfMetrics
        | Entity::CpuMetrics
        | Entity::MemoryMetrics
        | Entity::DiskMetrics
        | Entity::ProcessMetrics => Some(Dataset {
            raw_table: "serviceradar.timeseries_metrics",
            hourly_table: Some("serviceradar.timeseries_metrics_hourly"),
            time_column: "timestamp",
        }),
        Entity::Logs => Some(Dataset {
            raw_table: "serviceradar.logs",
            hourly_table: None,
            time_column: "timestamp",
        }),
        Entity::Events | Entity::SecurityFindings | Entity::ScanActivity | Entity::DnsActivity => {
            Some(Dataset {
                raw_table: "serviceradar.events",
                hourly_table: None,
                time_column: "time",
            })
        }
        _ => None,
    }
}

fn dataset_sql(plan: &QueryPlan, dataset: Dataset) -> Result<TranslateResponse> {
    let use_hourly = should_use_hourly_mv(plan, dataset);
    let table = if use_hourly {
        dataset.hourly_table.unwrap_or(dataset.raw_table)
    } else {
        dataset.raw_table
    };
    let time_column = if use_hourly {
        "bucket"
    } else {
        dataset.time_column
    };
    let (select, group) = stats_select(plan, use_hourly)?;
    let (where_sql, params) = time_predicate(plan, time_column);
    let sql = format!(
        "SELECT {select} FROM {table}{where_sql}{group} LIMIT {limit}",
        limit = plan.limit.max(1)
    );

    Ok(TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: None,
    })
}

fn should_use_hourly_mv(plan: &QueryPlan, dataset: Dataset) -> bool {
    if dataset.hourly_table.is_none() {
        return false;
    }
    if plan.stats.is_none() && plan.downsample.is_none() {
        return false;
    }
    if has_unsupported_mv_filter(&plan.filters) {
        return false;
    }
    if stats_group_by(plan.stats.as_ref()).is_some() {
        return false;
    }
    let Some(range) = plan.time_range.as_ref() else {
        return false;
    };
    range
        .end
        .signed_duration_since(range.start)
        .ge(&ChronoDuration::hours(HOURLY_MV_THRESHOLD_HOURS))
}

fn has_unsupported_mv_filter(filters: &[Filter]) -> bool {
    filters.iter().any(|filter| {
        let field = filter.field.to_ascii_lowercase();
        !matches!(
            field.as_str(),
            "time" | "timestamp" | "device_id" | "metric_name" | "metric_type"
        )
    })
}

fn stats_select(plan: &QueryPlan, use_hourly: bool) -> Result<(String, String)> {
    let Some(stats) = plan.stats.as_ref() else {
        return Ok(("*".to_string(), String::new()));
    };

    if stats.aggregations.is_empty() {
        return Ok((stats.as_raw().to_string(), String::new()));
    }

    let mut select = Vec::new();
    for agg in &stats.aggregations {
        select.push(starrocks_agg(agg, use_hourly)?);
    }
    if let Some(group_cols) = stats_group_by(Some(stats)) {
        for col in group_cols.split(',') {
            let col = col.trim();
            if !col.is_empty() {
                select.push(col.to_string());
            }
        }
        Ok((select.join(", "), format!(" GROUP BY {group_cols}")))
    } else {
        Ok((select.join(", "), String::new()))
    }
}

fn stats_group_by(stats: Option<&crate::parser::StatsSpec>) -> Option<String> {
    let raw = stats?.as_raw();
    let lowered = raw.to_ascii_lowercase();
    let idx = lowered.rfind(" by ")?;
    let cols = raw[idx + 4..].trim();
    if cols.is_empty() {
        None
    } else {
        Some(cols.to_string())
    }
}

fn starrocks_agg(agg: &StatsAggregation, use_hourly: bool) -> Result<String> {
    let alias = if agg.alias.is_empty() {
        String::new()
    } else {
        format!(" AS {}", agg.alias)
    };
    let field = agg.field.as_deref().unwrap_or("*");
    let expr = if use_hourly {
        hourly_agg(&agg.agg_type, field)?
    } else {
        let field = starrocks_flow_field(field);
        match agg.agg_type {
            StatsAggType::Sum => format!("SUM({field})"),
            StatsAggType::Count => format!("COUNT({field})"),
            StatsAggType::Avg => format!("AVG({field})"),
            StatsAggType::Min => format!("MIN({field})"),
            StatsAggType::Max => format!("MAX({field})"),
        }
    };
    Ok(expr + &alias)
}

fn starrocks_flow_field(field: &str) -> String {
    match field {
        "bytes_total" => "(COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0))".to_string(),
        "packets_total" => "(COALESCE(packets_in, 0) + COALESCE(packets_out, 0))".to_string(),
        other => other.to_string(),
    }
}

fn hourly_agg(agg_type: &StatsAggType, field: &str) -> Result<String> {
    match (agg_type, field) {
        (StatsAggType::Sum, "bytes_in") => Ok("SUM(bytes_in)".to_string()),
        (StatsAggType::Sum, "bytes_out") => Ok("SUM(bytes_out)".to_string()),
        (StatsAggType::Sum, "bytes_total") => {
            Ok("SUM(bytes_in) + SUM(bytes_out)".to_string())
        }
        (StatsAggType::Sum, "packets_total") => {
            Ok("SUM(packets_in) + SUM(packets_out)".to_string())
        }
        (StatsAggType::Sum, "packets_in") => Ok("SUM(packets_in)".to_string()),
        (StatsAggType::Sum, "packets_out") => Ok("SUM(packets_out)".to_string()),
        (StatsAggType::Count, "*") | (StatsAggType::Count, "id") => {
            Ok("SUM(flow_count)".to_string())
        }
        (StatsAggType::Avg, "value") | (StatsAggType::Avg, "usage_percent") => {
            Ok("AVG(avg_value)".to_string())
        }
        (StatsAggType::Min, "value") => Ok("MIN(min_value)".to_string()),
        (StatsAggType::Max, "value") => Ok("MAX(max_value)".to_string()),
        (StatsAggType::Count, "value") => Ok("SUM(sample_count)".to_string()),
        _ => Err(ServiceError::NotImplemented(format!(
            "starrocks_unsupported_mv_aggregation: {agg_type:?}({field})"
        ))),
    }
}

fn time_predicate(plan: &QueryPlan, time_column: &str) -> (String, Vec<BindParam>) {
    match &plan.time_range {
        Some(range) => (
            format!(
                " WHERE `{time_column}` >= '{}' AND `{time_column}` < '{}'",
                range.start.to_rfc3339_opts(SecondsFormat::Secs, true),
                range.end.to_rfc3339_opts(SecondsFormat::Secs, true)
            ),
            vec![
                BindParam::timestamptz(range.start),
                BindParam::timestamptz(range.end),
            ],
        ),
        None => {
            let end = Utc::now();
            let start = end - chrono::Duration::hours(1);
            (
                format!(
                    " WHERE `{time_column}` >= '{}' AND `{time_column}` < '{}'",
                    start.to_rfc3339_opts(SecondsFormat::Secs, true),
                    end.to_rfc3339_opts(SecondsFormat::Secs, true)
                ),
                vec![BindParam::timestamptz(start), BindParam::timestamptz(end)],
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::AppConfig;
    use crate::parser;
    use crate::query::{build_query_plan, QueryDirection, QueryRequest};
    use std::time::Duration as StdDuration;

    fn config() -> AppConfig {
        AppConfig {
            listen_addr: "127.0.0.1:0".parse().unwrap(),
            database_url: "postgres://example/db".to_string(),
            age_graph_name: "platform_graph".to_string(),
            max_pool_size: 1,
            database_ca_pem: None,
            database_client_cert_pem: None,
            database_client_key_pem: None,
            database_tls_server_name: None,
            api_key: None,
            api_key_kv_key: None,
            allowed_origins: None,
            cursor_secret: "test-cursor-secret".to_string(),
            max_cursor_offset: 100_000,
            default_limit: 100,
            max_limit: 500,
            request_timeout: StdDuration::from_secs(30),
            db_statement_timeout: StdDuration::from_secs(30),
            rate_limit_max_requests: 120,
            rate_limit_window: StdDuration::from_secs(60),
        }
    }

    fn plan(query: &str) -> QueryPlan {
        let ast = parser::parse(query).expect("parse");
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: Some("starrocks".into()),
        };
        build_query_plan(&config(), &request, ast).expect("plan")
    }

    #[test]
    fn flow_map_stats_group_by_endpoints_and_rewrite_bytes_total() {
        let compiled = translate(&plan(
            r#"in:flows time:last_1h stats:"sum(bytes_total) as bytes_total, sum(packets_total) as packets_total, count(*) as flow_count by src_endpoint_ip,dst_endpoint_ip" limit:120"#,
        ))
        .expect("compile");
        assert!(compiled
            .sql
            .contains("FROM serviceradar.ocsf_network_activity"));
        assert!(compiled.sql.contains("COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0)"));
        assert!(compiled.sql.contains("GROUP BY src_endpoint_ip,dst_endpoint_ip"));
        assert!(!compiled.sql.contains("ocsf_network_activity_hourly"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_stats_compile_to_starrocks_sql_without_postgres_functions() {
        let compiled = translate(&plan(
            r#"in:flows time:last_1h stats:"sum(bytes_in) as bytes_in" limit:10"#,
        ))
        .expect("compile");
        assert!(compiled
            .sql
            .contains("FROM serviceradar.ocsf_network_activity"));
        assert!(compiled.sql.contains("SUM(bytes_in) AS bytes_in"));
        assert!(compiled.sql.contains("LIMIT 10"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn long_window_flow_stats_select_the_hourly_mv() {
        let compiled = translate(&plan(
            r#"in:flows time:last_7d stats:"sum(bytes_in) as bytes_in" limit:10"#,
        ))
        .expect("compile");
        assert!(compiled
            .sql
            .contains("FROM serviceradar.ocsf_network_activity_hourly"));
        assert!(compiled.sql.contains("SUM(bytes_in) AS bytes_in"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn unsupported_mv_filters_fall_back_to_raw_flows() {
        let compiled = translate(&plan(
            r#"in:flows time:last_7d src_endpoint_ip:192.0.2.10 stats:"sum(bytes_in) as bytes_in" limit:10"#,
        ))
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity ")
                || compiled
                    .sql
                    .contains("FROM serviceradar.ocsf_network_activity WHERE")
        );
        assert!(!compiled.sql.contains("ocsf_network_activity_hourly"));
    }

    #[test]
    fn timeseries_metrics_compile_to_starrocks_sql() {
        let compiled = translate(&plan(
            r#"in:timeseries_metrics time:last_1h stats:"avg(value) as avg_value" limit:20"#,
        ))
        .expect("compile");
        assert!(compiled
            .sql
            .contains("FROM serviceradar.timeseries_metrics"));
        assert!(compiled.sql.contains("AVG(value) AS avg_value"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn long_window_cpu_metrics_select_the_hourly_mv() {
        let compiled = translate(&plan(
            r#"in:cpu_metrics time:last_7d stats:"avg(usage_percent) as avg_usage" limit:20"#,
        ))
        .expect("compile");
        assert!(compiled
            .sql
            .contains("FROM serviceradar.timeseries_metrics_hourly"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn logs_and_events_compile_to_starrocks_sql() {
        let logs = translate(&plan("in:logs time:last_1h limit:5")).expect("logs");
        assert!(logs.sql.contains("FROM serviceradar.logs"));
        assert!(logs.sql.contains("`timestamp`"));

        let events = translate(&plan("in:events time:last_1h limit:5")).expect("events");
        assert!(events.sql.contains("FROM serviceradar.events"));
        assert!(events.sql.contains("`time`"));
        refute_postgres(&logs.sql);
        refute_postgres(&events.sql);
    }

    #[test]
    fn current_alert_state_stays_a_capability_error() {
        let err = translate(&plan("in:alerts time:last_1h limit:5")).expect_err("alerts");
        assert!(err.to_string().contains("starrocks_unsupported_entity"));
    }

    #[test]
    fn unsupported_entities_return_a_capability_error() {
        let err = translate(&plan("in:devices time:last_1h limit:5")).expect_err("devices");
        assert!(err.to_string().contains("starrocks_unsupported_entity"));
    }

    struct RecordingExecutor {
        sql: std::sync::Mutex<Option<String>>,
        rows: Vec<Value>,
    }

    impl SqlExecutor for RecordingExecutor {
        fn execute_sql(&self, sql: &str) -> Result<Vec<Value>> {
            *self.sql.lock().expect("sql lock") = Some(sql.to_string());
            Ok(self.rows.clone())
        }
    }

    #[test]
    fn execute_plan_runs_compiled_starrocks_sql_not_postgres() {
        let executor = RecordingExecutor {
            sql: std::sync::Mutex::new(None),
            rows: vec![serde_json::json!({"bytes_in": 1200, "id": "flow-alpha-0001"})],
        };
        let response = execute_plan(
            &plan(r#"in:flows time:last_1h stats:"sum(bytes_in) as bytes_in" limit:10"#),
            Some(&executor),
        )
        .expect("execute");
        let sql = executor.sql.lock().expect("sql").clone().expect("captured");
        assert!(sql.contains("FROM serviceradar.ocsf_network_activity"));
        refute_postgres(&sql);
        assert_eq!(response.results.len(), 1);
        assert_eq!(response.results[0]["id"], "flow-alpha-0001");
        assert_eq!(response.pagination.limit, Some(10));
    }

    #[test]
    fn execute_plan_without_executor_is_a_capability_error() {
        let err =
            execute_plan(&plan("in:flows time:last_1h limit:5"), None).expect_err("unconfigured");
        assert!(err.to_string().contains("starrocks_not_configured"));
    }

    #[test]
    fn execute_plan_does_not_fall_back_to_postgres_for_devices() {
        let executor = RecordingExecutor {
            sql: std::sync::Mutex::new(None),
            rows: vec![serde_json::json!({"leaked": true})],
        };
        let err = execute_plan(&plan("in:devices time:last_1h limit:5"), Some(&executor))
            .expect_err("devices");
        assert!(err.to_string().contains("starrocks_unsupported_entity"));
        assert!(executor.sql.lock().expect("sql").is_none());
    }

    #[test]
    fn http_payload_rows_preserve_column_names() {
        let payload = serde_json::json!({
            "meta": [{"name": "id"}, {"name": "bytes_in"}],
            "data": [["flow-alpha-0001", 1200]]
        });
        let rows = rows_from_http_payload(payload);
        assert_eq!(rows[0]["id"], "flow-alpha-0001");
        assert_eq!(rows[0]["bytes_in"], 1200);
    }

    fn refute_postgres(sql: &str) {
        assert!(!sql.to_ascii_lowercase().contains("time_bucket"));
        assert!(!sql.to_ascii_lowercase().contains("::timestamptz"));
    }
}
