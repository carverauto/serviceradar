use super::{PaginationMeta, QueryPlan, QueryResponse, TranslateResponse, types::BindParam};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, StatsAggType, StatsAggregation},
};
use chrono::{SecondsFormat, Utc};
use serde_json::Value;

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
        let body = serde_json::to_vec(&serde_json::json!({ "query": sql })).map_err(|err| {
            ServiceError::Internal(anyhow::anyhow!("starrocks_http_encode: {err}"))
        })?;
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
    time_column: &'static str,
}

fn dataset_for(entity: &Entity) -> Option<Dataset> {
    match entity {
        Entity::Flows | Entity::AttributedFlows => Some(Dataset {
            raw_table: "serviceradar.ocsf_network_activity",
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
            time_column: "timestamp",
        }),
        Entity::Logs => Some(Dataset {
            raw_table: "serviceradar.logs",
            time_column: "timestamp",
        }),
        Entity::Events | Entity::SecurityFindings | Entity::ScanActivity | Entity::DnsActivity => {
            Some(Dataset {
                raw_table: "serviceradar.events",
                time_column: "time",
            })
        }
        _ => None,
    }
}

const FLOW_PROTOCOL_GROUP_SQL: &str =
    "CASE WHEN protocol_num = 6 THEN 'tcp' WHEN protocol_num = 17 THEN 'udp' ELSE 'other' END";
const FLOW_BYTES_TOTAL_SQL: &str = "(COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0))";
const FLOW_PACKETS_TOTAL_SQL: &str = "(COALESCE(packets_in, 0) + COALESCE(packets_out, 0))";
const FLOW_ROW_SELECT: &str = "id, time, device_uid, src_endpoint_ip, dst_endpoint_ip, src_endpoint_port, dst_endpoint_port, protocol_num, protocol_name, CASE WHEN protocol_num = 6 THEN 'tcp' WHEN protocol_num = 17 THEN 'udp' ELSE 'other' END AS protocol_group, COALESCE(bytes_total, COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0)) AS bytes_total, COALESCE(packets_total, COALESCE(packets_in, 0) + COALESCE(packets_out, 0)) AS packets_total, bytes_in, bytes_out, packets_in, packets_out, sampling_rate, direction_label, sampler_address, dst_service_label, src_as_number, dst_as_number, tcp_flags, input_snmp, output_snmp, start_time, end_time, pid, comm, cmdline, CASE WHEN pid IS NULL THEN 'unmatched' ELSE 'attributed' END AS attribution_status";

fn dataset_sql(plan: &QueryPlan, dataset: Dataset) -> Result<TranslateResponse> {
    let joins = catalog_joins(plan, dataset)?;
    let time_column = dataset.time_column;
    let from = from_with_catalog_joins(dataset.raw_table, &joins);
    let (mut where_sql, params) = time_predicate(plan, time_column, !joins.is_empty());
    for filter in &plan.filters {
        where_sql.push_str(" AND ");
        where_sql.push_str(&filter_sql(plan, filter)?);
    }
    if let Some(downsample) = plan.downsample.as_ref() {
        let sql = downsample_sql(plan, downsample, &from, &where_sql)?;
        return Ok(TranslateResponse {
            sql,
            params,
            pagination: PaginationMeta {
                next_cursor: None,
                prev_cursor: None,
                limit: Some(plan.limit),
            },
            viz: None,
        });
    }
    let (select, group) = stats_select(plan, dataset)?;
    let order = order_sql(plan, time_column)?;
    let sql = format!(
        "SELECT {select} FROM {from}{where_sql}{group}{order} LIMIT {limit} OFFSET {offset}",
        limit = plan.limit.max(1),
        offset = plan.offset.max(0)
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

const CNPG_CATALOG: &str = "cnpg_platform.platform";

#[derive(Clone, Copy, PartialEq, Eq)]
enum CatalogJoin {
    #[allow(dead_code)]
    Attribution,
    PrefixTags,
    Devices,
}

impl CatalogJoin {
    fn table(self) -> &'static str {
        match self {
            Self::Attribution => "flow_process_attribution_current",
            Self::PrefixTags => "prefix_tags_catalog",
            Self::Devices => "ocsf_devices",
        }
    }

    fn sql(self) -> &'static str {
        match self {
            Self::Attribution => {
                "INNER JOIN cnpg_platform.platform.flow_process_attribution_current AS attr ON attr.local_ip = f.src_endpoint_ip AND attr.remote_ip = f.dst_endpoint_ip"
            }
            Self::PrefixTags => {
                "LEFT JOIN cnpg_platform.platform.prefix_tags_catalog AS tags ON tags.prefix = concat(f.src_endpoint_ip, '/32')"
            }
            Self::Devices => {
                "LEFT JOIN cnpg_platform.platform.ocsf_devices AS dev ON dev.uid = f.device_uid"
            }
        }
    }
}

fn catalog_joins(plan: &QueryPlan, dataset: Dataset) -> Result<Vec<CatalogJoin>> {
    // Historical attributed_flows filter pid/comm on the observation row
    // (same snapshot semantics as CNPG ocsf_payload attribution). The JDBC
    // catalog is for live hostname/prefix enrichment, not this page.
    let wants_prefix = plan_mentions(plan, &["prefix_tag", "live_prefix_tag"]);
    let wants_device = plan_mentions(plan, &["hostname", "device_name"]);
    if !(wants_prefix || wants_device) {
        return Ok(Vec::new());
    }
    if dataset.raw_table != "serviceradar.ocsf_network_activity" {
        return Err(ServiceError::NotImplemented(
            "starrocks_catalog_unsupported_entity".to_string(),
        ));
    }
    let mut joins = Vec::new();
    if wants_prefix {
        joins.push(CatalogJoin::PrefixTags);
    }
    if wants_device {
        joins.push(CatalogJoin::Devices);
    }
    let _ = CNPG_CATALOG;
    Ok(joins)
}

fn plan_mentions(plan: &QueryPlan, fields: &[&str]) -> bool {
    let hit = |name: &str| {
        let name = name.to_ascii_lowercase();
        fields.iter().any(|field| name == *field)
    };
    if plan.filters.iter().any(|filter| hit(&filter.field)) {
        return true;
    }
    if let Some(stats) = plan.stats.as_ref() {
        let raw = stats.as_raw().to_ascii_lowercase();
        if fields.iter().any(|field| {
            raw.split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                .any(|tok| tok == *field)
        }) {
            return true;
        }
    }
    false
}

fn from_with_catalog_joins(table: &str, joins: &[CatalogJoin]) -> String {
    if joins.is_empty() {
        return table.to_string();
    }
    let mut from = format!("{table} AS f");
    for join in joins {
        from.push(' ');
        from.push_str(join.sql());
        let _ = join.table();
    }
    from
}

fn stats_select(plan: &QueryPlan, dataset: Dataset) -> Result<(String, String)> {
    let Some(stats) = plan.stats.as_ref() else {
        let select = if dataset.raw_table.contains("ocsf_network_activity") {
            FLOW_ROW_SELECT.to_string()
        } else {
            "*".to_string()
        };
        return Ok((select, String::new()));
    };

    if stats.aggregations.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "starrocks_raw_stats_unsupported".into(),
        ));
    }

    let mut select = Vec::new();
    for agg in &stats.aggregations {
        select.push(starrocks_agg(plan, agg)?);
    }
    if let Some(group_cols) = stats_group_by(Some(stats)) {
        let mut rewritten = Vec::new();
        for col in group_cols.split(',') {
            let col = col.trim();
            if col.is_empty() {
                continue;
            }
            let expr = field_sql(plan, col)?;
            select.push(format!("{expr} AS {alias}", alias = group_alias(col)));
            rewritten.push(expr);
        }
        Ok((
            select.join(", "),
            format!(" GROUP BY {}", rewritten.join(", ")),
        ))
    } else {
        Ok((select.join(", "), String::new()))
    }
}

fn group_alias(col: &str) -> String {
    let trimmed = col.trim();
    if let Some(rest) = trimmed.strip_prefix("src_cidr:") {
        return format!("src_cidr_{rest}");
    }
    if let Some(rest) = trimmed.strip_prefix("dst_cidr:") {
        return format!("dst_cidr_{rest}");
    }
    match trimmed {
        "dst_port" => "dst_endpoint_port".to_string(),
        "src_port" => "src_endpoint_port".to_string(),
        "app" => "app".to_string(),
        other => other.to_string(),
    }
}

fn ipv4_prefix_sql(column: &str, prefix: &str) -> String {
    match prefix {
        "8" => format!("CONCAT(SPLIT_PART({column}, '.', 1), '.0.0.0')"),
        "16" => {
            format!(
                "CONCAT(SPLIT_PART({column}, '.', 1), '.', SPLIT_PART({column}, '.', 2), '.0.0')"
            )
        }
        "24" => format!(
            "CONCAT(SPLIT_PART({column}, '.', 1), '.', SPLIT_PART({column}, '.', 2), '.', SPLIT_PART({column}, '.', 3), '.0')"
        ),
        _ => column.to_string(),
    }
}

fn downsample_sql(
    plan: &QueryPlan,
    downsample: &crate::parser::DownsampleSpec,
    from: &str,
    where_sql: &str,
) -> Result<String> {
    let bucket = downsample.bucket_seconds.max(1);
    let value = field_sql(
        plan,
        downsample.value_field.as_deref().unwrap_or("bytes_total"),
    )?;
    let agg = match downsample.agg {
        crate::parser::DownsampleAgg::Sum => format!("SUM({value})"),
        crate::parser::DownsampleAgg::Avg => format!("AVG({value})"),
        crate::parser::DownsampleAgg::Min => format!("MIN({value})"),
        crate::parser::DownsampleAgg::Max => format!("MAX({value})"),
        crate::parser::DownsampleAgg::Count => "COUNT(*)".to_string(),
        crate::parser::DownsampleAgg::Rate | crate::parser::DownsampleAgg::RateSum => {
            format!("SUM({value})")
        }
    };
    let series = match downsample.series.as_deref() {
        Some(field) => format!("CAST({} AS STRING)", field_sql(plan, field)?),
        None => "'all'".to_string(),
    };
    let time = dataset_for(&plan.entity).unwrap().time_column;
    Ok(format!(
        "SELECT time_slice({time}, INTERVAL {bucket} SECOND) AS timestamp, {series} AS series, {agg} AS value FROM {from}{where_sql} GROUP BY 1, 2 ORDER BY 1 LIMIT {limit} OFFSET {offset}",
        limit = plan.limit.max(1),
        offset = plan.offset.max(0)
    ))
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

fn starrocks_agg(plan: &QueryPlan, agg: &StatsAggregation) -> Result<String> {
    let field = match agg.field.as_deref() {
        None | Some("*") if matches!(agg.agg_type, StatsAggType::Count) => "*".to_string(),
        Some(field) => field_sql(plan, field)?,
        None => {
            return Err(ServiceError::InvalidRequest(
                "aggregate requires a field".into(),
            ));
        }
    };
    let function = match agg.agg_type {
        StatsAggType::Sum => "SUM",
        StatsAggType::Count => "COUNT",
        StatsAggType::Avg => "AVG",
        StatsAggType::Min => "MIN",
        StatsAggType::Max => "MAX",
    };
    let alias = if agg.alias.is_empty() {
        String::new()
    } else {
        validate_identifier(&agg.alias)?;
        format!(" AS {}", agg.alias)
    };
    Ok(format!("{function}({field}){alias}"))
}

fn validate_identifier(value: &str) -> Result<()> {
    if value.is_empty()
        || !value
            .bytes()
            .enumerate()
            .all(|(i, c)| c == b'_' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit()))
    {
        return Err(ServiceError::InvalidRequest(
            "invalid StarRocks identifier".into(),
        ));
    }
    Ok(())
}

fn field_sql(plan: &QueryPlan, field: &str) -> Result<String> {
    let dataset = dataset_for(&plan.entity).unwrap();
    let flow = matches!(plan.entity, Entity::Flows | Entity::AttributedFlows);
    let qualified = flow && !catalog_joins(plan, dataset)?.is_empty();
    let column = |name: &str| {
        if qualified {
            format!("f.{name}")
        } else {
            name.to_string()
        }
    };
    if flow {
        match field {
            "attribution_status" => {
                return Ok(format!(
                    "CASE WHEN {} IS NULL THEN 'unmatched' ELSE 'attributed' END",
                    column("pid")
                ));
            }
            "protocol_group" | "proto_group" => {
                return Ok(FLOW_PROTOCOL_GROUP_SQL.replace("protocol_num", &column("protocol_num")));
            }
            "bytes_total" => {
                return Ok(FLOW_BYTES_TOTAL_SQL
                    .replace("bytes_in", &column("bytes_in"))
                    .replace("bytes_out", &column("bytes_out")));
            }
            "packets_total" => {
                return Ok(FLOW_PACKETS_TOTAL_SQL
                    .replace("packets_in", &column("packets_in"))
                    .replace("packets_out", &column("packets_out")));
            }
            "src_ip" => return Ok(column("src_endpoint_ip")),
            "dst_ip" => return Ok(column("dst_endpoint_ip")),
            "src_port" => return Ok(column("src_endpoint_port")),
            "dst_port" => return Ok(column("dst_endpoint_port")),
            "app" => {
                return Ok(format!(
                    "COALESCE({}, 'unknown')",
                    column("dst_service_label")
                ));
            }
            "hostname" | "device_name" => return Ok("dev.hostname".into()),
            _ => {}
        }
        for (prefix, name) in [
            ("src_cidr:", "src_endpoint_ip"),
            ("dst_cidr:", "dst_endpoint_ip"),
        ] {
            if let Some(bits) = field.strip_prefix(prefix) {
                if matches!(bits, "8" | "16" | "24") {
                    return Ok(ipv4_prefix_sql(&column(name), bits));
                }
                return Err(ServiceError::InvalidRequest(
                    "unsupported CIDR grouping".into(),
                ));
            }
        }
    }
    let fields = match dataset.raw_table {
        "serviceradar.ocsf_network_activity" => {
            "id device_uid time src_endpoint_ip dst_endpoint_ip src_endpoint_port dst_endpoint_port protocol_num protocol_name direction_label dst_service_label start_time end_time src_as_number dst_as_number tcp_flags partition input_snmp output_snmp src_mac dst_mac src_mac_vendor dst_mac_vendor src_hosting_provider dst_hosting_provider protocol_source direction_source dst_service_source src_prefix_tags dst_prefix_tags bytes_in bytes_out packets_in packets_out sampling_rate attribution_version sampler_address pid comm cmdline workload_identity"
        }
        "serviceradar.timeseries_metrics" => {
            "timestamp gateway_id series_key agent_id metric_name metric_type device_id value unit if_index partition scale is_delta counter_width target_device_ip tags usage_percent"
        }
        "serviceradar.logs" => {
            "id timestamp ingest_identity severity_text severity_number body service_name source ingest_agent_id ingest_partition trace_id span_id event_name source_ip service_version observed_timestamp"
        }
        "serviceradar.events" => {
            "id time class_uid category_uid type_uid activity_id severity_id severity source src_endpoint_ip firewall_rule_name source_type message activity_name status status_id log_name log_provider trace_id span_id"
        }
        _ => "",
    };
    if fields.split_whitespace().any(|name| name == field) {
        Ok(column(field))
    } else {
        Err(ServiceError::InvalidRequest(format!(
            "unsupported StarRocks field: {field}"
        )))
    }
}

fn filter_sql(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    use crate::parser::FilterOp;
    let field = field_sql(plan, &filter.field)?;
    let literal = |value: &str| format!("'{}'", value.replace('\\', "\\\\").replace('\'', "''"));
    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "!=",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        FilterOp::Like => "LIKE",
        FilterOp::NotLike => "NOT LIKE",
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Err(ServiceError::InvalidRequest("empty filter list".into()));
            }
            let op = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            return Ok(format!(
                "{field} {op} ({})",
                values
                    .iter()
                    .map(|v| literal(v))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
    };
    Ok(format!(
        "{field} {op} {}",
        literal(filter.value.as_scalar()?)
    ))
}

fn order_sql(plan: &QueryPlan, time_column: &str) -> Result<String> {
    if plan.order.is_empty() {
        return Ok(if plan.stats.is_none() {
            format!(" ORDER BY {time_column} DESC")
        } else {
            String::new()
        });
    }
    let groups = stats_group_by(plan.stats.as_ref()).unwrap_or_default();
    let mut terms = Vec::new();
    for order in &plan.order {
        let field = if let Some(stats) = &plan.stats {
            if !stats
                .aggregations
                .iter()
                .any(|agg| agg.alias == order.field)
                && !groups.split(',').any(|col| group_alias(col) == order.field)
            {
                return Err(ServiceError::InvalidRequest(
                    "stats ordering requires a selected field".into(),
                ));
            }
            validate_identifier(&order.field)?;
            order.field.clone()
        } else {
            field_sql(plan, &order.field)?
        };
        let direction = match order.direction {
            crate::parser::OrderDirection::Asc => "ASC",
            crate::parser::OrderDirection::Desc => "DESC",
        };
        terms.push(format!("{field} {direction}"));
    }
    Ok(format!(" ORDER BY {}", terms.join(", ")))
}

fn time_predicate(
    plan: &QueryPlan,
    time_column: &str,
    qualify_flow: bool,
) -> (String, Vec<BindParam>) {
    let column = if qualify_flow {
        format!("f.`{time_column}`")
    } else {
        format!("`{time_column}`")
    };
    match &plan.time_range {
        Some(range) => (
            format!(
                " WHERE {column} >= '{}' AND {column} < '{}'",
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
                    " WHERE {column} >= '{}' AND {column} < '{}'",
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
    use crate::query::{QueryDirection, QueryRequest, build_query_plan};
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
    fn rejects_untrusted_sql_before_execution() {
        let executor = RecordingExecutor {
            sql: std::sync::Mutex::new(None),
            rows: vec![],
        };
        for query in [
            r#"in:flows time:last_1h stats:"(SELECT body FROM serviceradar.logs LIMIT 1) AS leaked" limit:1"#,
            r#"in:flows time:last_1h stats:"sum(body) as leaked""#,
            r#"in:flows time:last_1h stats:"sum(bytes_in) as total by body""#,
            r#"in:flows time:last_1h stats:"sum(bytes_in) as total;drop""#,
            "in:flows time:last_1h bucket:1m series:body",
            "in:flows time:last_1h unknown_field:value",
        ] {
            assert!(
                execute_plan(&plan(query), Some(&executor)).is_err(),
                "{query}"
            );
        }
        assert!(executor.sql.lock().unwrap().is_none());
    }

    #[test]
    fn filtered_stats_preserve_order_and_cursor_offset() {
        let mut request = QueryRequest {
            query: r#"in:flows time:last_1h device_uid:device-example protocol_num:6 stats:"sum(bytes_total) as volume by src_endpoint_ip" sort:volume:desc limit:2"#.into(),
            limit: None,
            cursor: Some(crate::pagination::encode_cursor(2, &config().cursor_secret).unwrap()),
            direction: QueryDirection::Next,
            mode: Some("starrocks".into()),
        };
        let compiled = crate::query::translate_request(&config(), request.clone()).unwrap();
        assert!(
            compiled.sql.contains("AND device_uid = 'device-example'"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("AND protocol_num = '6'"));
        assert!(
            compiled
                .sql
                .ends_with("ORDER BY volume DESC LIMIT 2 OFFSET 2")
        );
        let next = compiled.pagination.next_cursor.unwrap();
        assert_eq!(
            crate::pagination::decode_cursor(&next, &config().cursor_secret, 100).unwrap(),
            4
        );
        request.cursor = Some(next);
        let next_page = crate::query::translate_request(&config(), request).unwrap();
        assert!(next_page.sql.ends_with("OFFSET 4"));
    }

    #[test]
    fn unmatched_attribution_and_long_downsample_use_raw_rows() {
        let compiled = translate(&plan(r#"in:attributed_flows time:last_7d attribution_status:unmatched stats:"count(*) as total by attribution_status""#)).unwrap();
        assert!(compiled.sql.contains("END = 'unmatched'"));
        assert!(compiled.sql.contains("GROUP BY CASE WHEN pid IS NULL"));
        assert!(!compiled.sql.contains("AND pid IS NOT NULL"));
        let chart = translate(&plan(
            "in:flows time:last_7d bucket:1h agg:sum value_field:bytes_total",
        ))
        .unwrap();
        assert!(chart.sql.contains("time_slice(time, INTERVAL 3600 SECOND)"));
        assert!(!chart.sql.contains("_hourly"));
    }

    #[test]
    fn flow_map_stats_group_by_endpoints_and_rewrite_bytes_total() {
        let compiled = translate(&plan(
            r#"in:flows time:last_1h stats:"sum(bytes_total) as bytes_total, sum(packets_total) as packets_total, count(*) as flow_count by src_endpoint_ip,dst_endpoint_ip" limit:120"#,
        ))
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity")
        );
        assert!(
            compiled
                .sql
                .contains("COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0)")
        );
        assert!(
            compiled.sql.contains("GROUP BY src_endpoint_ip"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("dst_endpoint_ip"), "{}", compiled.sql);
        assert!(!compiled.sql.contains("ocsf_network_activity_hourly"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_row_select_projects_protocol_group_and_bytes_total() {
        let compiled = translate(&plan("in:flows time:last_1h limit:5")).expect("compile");
        assert!(
            compiled.sql.contains("AS protocol_group"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("AS bytes_total"), "{}", compiled.sql);
        assert!(
            compiled.sql.contains("ORDER BY time DESC"),
            "{}",
            compiled.sql
        );
        assert!(!compiled.sql.contains("SELECT *"), "{}", compiled.sql);
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_downsample_emits_timestamp_series_value() {
        let compiled = translate(&plan(
            "in:flows time:last_1h bucket:1m agg:sum value_field:bytes_total series:protocol_group limit:2000",
        ))
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("time_slice(time, INTERVAL 60 SECOND) AS timestamp"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("AS series"), "{}", compiled.sql);
        assert!(compiled.sql.contains("AS value"), "{}", compiled.sql);
        assert!(
            compiled.sql.contains("protocol_num = 6"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("GROUP BY 1, 2"), "{}", compiled.sql);
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_stats_compile_to_starrocks_sql_without_postgres_functions() {
        let compiled = translate(&plan(
            r#"in:flows time:last_1h stats:"sum(bytes_in) as bytes_in" limit:10"#,
        ))
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity")
        );
        assert!(compiled.sql.contains("SUM(bytes_in) AS bytes_in"));
        assert!(compiled.sql.contains("LIMIT 10"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn long_window_flow_stats_preserve_raw_window() {
        let compiled = translate(&plan(
            r#"in:flows time:last_7d stats:"sum(bytes_in) as bytes_in" limit:10"#,
        ))
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity WHERE")
        );
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
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.timeseries_metrics")
        );
        assert!(compiled.sql.contains("AVG(value) AS avg_value"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn long_window_cpu_metrics_preserve_raw_window() {
        let compiled = translate(&plan(
            r#"in:cpu_metrics time:last_7d stats:"avg(usage_percent) as avg_usage" limit:20"#,
        ))
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.timeseries_metrics WHERE")
        );
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
    fn attributed_flows_filter_persisted_pid_not_live_catalog_join() {
        let compiled =
            translate(&plan("in:attributed_flows time:last_1h limit:5")).expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity")
        );
        assert!(
            !compiled.sql.contains("AND pid IS NOT NULL"),
            "{}",
            compiled.sql
        );
        assert!(
            compiled.sql.contains("AS attribution_status"),
            "{}",
            compiled.sql
        );
        assert!(!compiled.sql.contains("flow_process_attribution_current"));
        assert!(!compiled.sql.contains("ocsf_network_activity_hourly"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_hostname_join_cnpg_devices() {
        let compiled = translate(&plan(
            r#"in:flows hostname:host-alpha time:last_1h stats:"sum(bytes_in) as bytes_in" limit:10"#,
        ))
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("cnpg_platform.platform.ocsf_devices AS dev")
        );
        assert!(compiled.sql.contains("dev.uid = f.device_uid"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn unsupported_prefix_tag_filter_returns_capability_error() {
        assert!(translate(&plan("in:flows prefix_tag:example time:last_1h limit:10")).is_err());
    }

    #[test]
    fn plain_flows_do_not_join_the_cnpg_catalog() {
        let compiled = translate(&plan("in:flows time:last_1h limit:5")).expect("compile");
        assert!(!compiled.sql.contains("cnpg_platform"));
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity")
        );
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
