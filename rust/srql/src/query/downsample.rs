use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    parser::{DownsampleAgg, Entity, Filter, FilterOp},
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::sql_query;
use diesel::sql_types::{Float8, Nullable, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    let sql = build_sql(plan)?;
    let params = build_params(plan)?;
    Ok((rewrite_placeholders(&sql), params))
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    let sql = build_sql(plan)?;
    let mut query = sql_query(rewrite_placeholders(&sql)).into_boxed::<Pg>();

    for bind in build_bind_values(plan)? {
        query = bind.apply(query);
    }

    let rows: Vec<DownsampleRow> = query
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(|row| {
            serde_json::json!({
                "timestamp": row.timestamp.to_rfc3339(),
                "series": row.series,
                "value": row.value,
            })
        })
        .collect())
}

fn build_sql(plan: &QueryPlan) -> Result<String> {
    let downsample = plan.downsample.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("downsample requires bucket:<duration>".into())
    })?;

    let (table, ts_col, value_col, forced_metric_type) = match plan.entity {
        Entity::TimeseriesMetrics => ("timeseries_metrics", "timestamp", "value", None),
        Entity::SnmpMetrics => ("timeseries_metrics", "timestamp", "value", Some("snmp")),
        Entity::RperfMetrics => ("timeseries_metrics", "timestamp", "value", Some("rperf")),
        Entity::CpuMetrics => ("cpu_metrics", "timestamp", "usage_percent", None),
        Entity::MemoryMetrics => ("memory_metrics", "timestamp", "usage_percent", None),
        Entity::DiskMetrics => ("disk_metrics", "timestamp", "usage_percent", None),
        Entity::ProcessMetrics => ("process_metrics", "timestamp", "cpu_usage", None),
        Entity::OtelMetrics => ("otel_metrics", "timestamp", "value", None),
        _ => {
            return Err(ServiceError::InvalidRequest(
                "downsample is only supported for metric entities".into(),
            ))
        }
    };

    let time_range = plan.time_range.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("downsample queries require time:<range>".into())
    })?;

    let series_expr = series_expr(plan, table)?;
    let agg_expr = agg_expr(downsample.agg, value_col);
    let bucket_secs = downsample.bucket_seconds;

    let mut clauses = Vec::new();
    clauses.push(format!("{ts_col} >= ?"));
    clauses.push(format!("{ts_col} <= ?"));

    if let Some(metric_type) = forced_metric_type {
        clauses.push("metric_type = ?".to_string());
        let _ = metric_type;
    }

    for filter in &plan.filters {
        let (clause, _) = filter_clause(&plan.entity, table, filter)?;
        clauses.push(clause);
    }

    let mut sql = format!(
        "SELECT time_bucket(make_interval(secs => {bucket_secs}), {ts_col}) AS timestamp, {series_expr} AS series, {agg_expr} AS value\nFROM {table}\nWHERE ",
    );
    sql.push_str(&clauses.join(" AND "));
    sql.push_str("\nGROUP BY 1, 2\nORDER BY 1 ASC\nLIMIT ? OFFSET ?");

    let _ = time_range;
    Ok(sql)
}

fn build_params(plan: &QueryPlan) -> Result<Vec<BindParam>> {
    Ok(build_bind_values(plan)?
        .into_iter()
        .map(|value| value.into_bind_param())
        .collect())
}

fn build_bind_values(plan: &QueryPlan) -> Result<Vec<SqlBindValue>> {
    let mut binds = Vec::new();

    let TimeRange { start, end } = plan.time_range.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("downsample queries require time:<range>".into())
    })?;

    binds.push(SqlBindValue::Timestamp(*start));
    binds.push(SqlBindValue::Timestamp(*end));

    if matches!(plan.entity, Entity::SnmpMetrics) {
        binds.push(SqlBindValue::Text("snmp".to_string()));
    } else if matches!(plan.entity, Entity::RperfMetrics) {
        binds.push(SqlBindValue::Text("rperf".to_string()));
    }

    for filter in &plan.filters {
        let (_, mut values) = filter_clause(&plan.entity, "unused", filter)?;
        binds.append(&mut values);
    }

    binds.push(SqlBindValue::BigInt(plan.limit));
    binds.push(SqlBindValue::BigInt(plan.offset));

    Ok(binds)
}

fn series_expr(plan: &QueryPlan, table: &str) -> Result<String> {
    let downsample = plan.downsample.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("downsample requires bucket:<duration>".into())
    })?;

    let Some(series) = downsample.series.as_deref() else {
        return Ok("NULL::text".to_string());
    };

    let series = series.trim().to_lowercase();

    let expr = match plan.entity {
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => {
            match series.as_str() {
                "metric_name" => "metric_name".to_string(),
                "metric_type" => "metric_type".to_string(),
                "device_id" => "device_id".to_string(),
                "poller_id" => "poller_id".to_string(),
                "agent_id" => "agent_id".to_string(),
                "partition" => "partition".to_string(),
                "target_device_ip" => "target_device_ip".to_string(),
                "if_index" => "if_index::text".to_string(),
                other => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "unsupported series field '{other}' for {table}"
                    )))
                }
            }
        }
        Entity::CpuMetrics => match series.as_str() {
            "device_id" => "device_id".to_string(),
            "host_id" => "host_id".to_string(),
            "poller_id" => "poller_id".to_string(),
            "agent_id" => "agent_id".to_string(),
            "core_id" => "core_id::text".to_string(),
            "label" => "label".to_string(),
            "cluster" => "cluster".to_string(),
            "partition" => "partition".to_string(),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )))
            }
        },
        Entity::MemoryMetrics => match series.as_str() {
            "device_id" => "device_id".to_string(),
            "host_id" => "host_id".to_string(),
            "poller_id" => "poller_id".to_string(),
            "agent_id" => "agent_id".to_string(),
            "partition" => "partition".to_string(),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )))
            }
        },
        Entity::DiskMetrics => match series.as_str() {
            "device_id" => "device_id".to_string(),
            "host_id" => "host_id".to_string(),
            "poller_id" => "poller_id".to_string(),
            "agent_id" => "agent_id".to_string(),
            "partition" => "partition".to_string(),
            "mount_point" => "mount_point".to_string(),
            "device_name" => "device_name".to_string(),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )))
            }
        },
        Entity::ProcessMetrics => match series.as_str() {
            "device_id" => "device_id".to_string(),
            "host_id" => "host_id".to_string(),
            "poller_id" => "poller_id".to_string(),
            "agent_id" => "agent_id".to_string(),
            "partition" => "partition".to_string(),
            "name" => "name".to_string(),
            "pid" => "pid::text".to_string(),
            "status" => "status".to_string(),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )))
            }
        },
        Entity::OtelMetrics => match series.as_str() {
            "metric_name" => "metric_name".to_string(),
            "metric_type" => "metric_type".to_string(),
            "service_name" => "service_name".to_string(),
            "span_name" => "span_name".to_string(),
            "component" => "component".to_string(),
            "level" => "level".to_string(),
            "unit" => "unit".to_string(),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )))
            }
        },
        _ => {
            return Err(ServiceError::InvalidRequest(
                "downsample is only supported for metric entities".into(),
            ))
        }
    };

    Ok(format!("coalesce({expr}, '')"))
}

fn agg_expr(agg: DownsampleAgg, value_col: &str) -> String {
    match agg {
        DownsampleAgg::Avg => format!("AVG({value_col})"),
        DownsampleAgg::Min => format!("MIN({value_col})"),
        DownsampleAgg::Max => format!("MAX({value_col})"),
        DownsampleAgg::Sum => format!("SUM({value_col})"),
        DownsampleAgg::Count => "COUNT(*)::double precision".to_string(),
    }
}

fn filter_clause(
    entity: &Entity,
    _table: &str,
    filter: &Filter,
) -> Result<(String, Vec<SqlBindValue>)> {
    match entity {
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => {
            timeseries_filter_clause(filter)
        }
        Entity::CpuMetrics => cpu_filter_clause(filter),
        Entity::MemoryMetrics => memory_filter_clause(filter),
        Entity::DiskMetrics => disk_filter_clause(filter),
        Entity::ProcessMetrics => process_filter_clause(filter),
        Entity::OtelMetrics => otel_metrics_filter_clause(filter),
        _ => Err(ServiceError::InvalidRequest(
            "downsample is only supported for metric entities".into(),
        )),
    }
}

fn text_clause(column: &str, filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} <> ?")
        }
        FilterOp::Like => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} ILIKE ?")
        }
        FilterOp::NotLike => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("NOT ({column} ILIKE ?)")
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(("1=0".to_string(), Vec::new()));
            }
            binds.push(SqlBindValue::TextArray(values));
            format!("{column} = ANY(?)")
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(("1=1".to_string(), Vec::new()));
            }
            binds.push(SqlBindValue::TextArray(values));
            format!("{column} <> ALL(?)")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for {column}: {:?}",
                filter.op
            )))
        }
    };
    Ok((clause, binds))
}

fn float_clause(
    column: &str,
    filter: &Filter,
    allow_ranges: bool,
) -> Result<(String, Vec<SqlBindValue>)> {
    let mut binds = Vec::new();
    let value = filter
        .value
        .as_scalar()?
        .parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest("invalid numeric value".into()))?;
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} <> ?")
        }
        FilterOp::Gt if allow_ranges => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} > ?")
        }
        FilterOp::Gte if allow_ranges => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} >= ?")
        }
        FilterOp::Lt if allow_ranges => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} < ?")
        }
        FilterOp::Lte if allow_ranges => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} <= ?")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{column} filter does not support operator {:?}",
                filter.op
            )))
        }
    };
    Ok((clause, binds))
}

fn int_clause(
    column: &str,
    filter: &Filter,
    allow_ranges: bool,
) -> Result<(String, Vec<SqlBindValue>)> {
    let mut binds = Vec::new();
    let value = filter
        .value
        .as_scalar()?
        .parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest("invalid integer value".into()))?;

    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} <> ?")
        }
        FilterOp::Gt if allow_ranges => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} > ?")
        }
        FilterOp::Gte if allow_ranges => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} >= ?")
        }
        FilterOp::Lt if allow_ranges => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} < ?")
        }
        FilterOp::Lte if allow_ranges => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} <= ?")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{column} filter does not support operator {:?}",
                filter.op
            )))
        }
    };

    Ok((clause, binds))
}

fn timeseries_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "poller_id" | "agent_id" | "metric_name" | "metric_type" | "device_id"
        | "target_device_ip" | "partition" => text_clause(filter.field.as_str(), filter),
        "if_index" => int_clause("if_index", filter, false),
        "value" => float_clause("value", filter, true),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample timeseries_metrics: '{other}'"
        ))),
    }
}

fn cpu_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "poller_id" | "agent_id" | "host_id" | "device_id" | "partition" | "cluster" | "label" => {
            text_clause(filter.field.as_str(), filter)
        }
        "core_id" => int_clause("core_id", filter, false),
        "usage_percent" => float_clause("usage_percent", filter, true),
        "frequency_hz" => float_clause("frequency_hz", filter, true),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample cpu_metrics: '{other}'"
        ))),
    }
}

fn memory_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "poller_id" | "agent_id" | "host_id" | "device_id" | "partition" => {
            text_clause(filter.field.as_str(), filter)
        }
        "usage_percent" => float_clause("usage_percent", filter, false),
        "total_bytes" => int_clause("total_bytes", filter, false),
        "used_bytes" => int_clause("used_bytes", filter, false),
        "available_bytes" => int_clause("available_bytes", filter, false),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample memory_metrics: '{other}'"
        ))),
    }
}

fn disk_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "poller_id" | "agent_id" | "host_id" | "device_id" | "partition" | "mount_point"
        | "device_name" => text_clause(filter.field.as_str(), filter),
        "usage_percent" => float_clause("usage_percent", filter, false),
        "total_bytes" => int_clause("total_bytes", filter, false),
        "used_bytes" => int_clause("used_bytes", filter, false),
        "available_bytes" => int_clause("available_bytes", filter, false),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample disk_metrics: '{other}'"
        ))),
    }
}

fn process_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "poller_id" | "agent_id" | "host_id" | "device_id" | "partition" | "name" | "status"
        | "start_time" => text_clause(filter.field.as_str(), filter),
        "pid" => int_clause("pid", filter, false),
        "cpu_usage" => float_clause("cpu_usage", filter, true),
        "memory_usage" => int_clause("memory_usage", filter, true),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample process_metrics: '{other}'"
        ))),
    }
}

fn otel_metrics_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "metric_name" | "metric_type" | "service_name" | "span_name" | "span_kind" | "component"
        | "level" | "unit" | "http_method" | "http_route" | "http_status_code" | "grpc_service"
        | "grpc_method" | "grpc_status_code" => text_clause(filter.field.as_str(), filter),
        "value" | "duration_ms" => float_clause(filter.field.as_str(), filter, true),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample otel_metrics: '{other}'"
        ))),
    }
}

#[derive(Debug, QueryableByName)]
struct DownsampleRow {
    #[diesel(sql_type = Timestamptz)]
    timestamp: DateTime<Utc>,
    #[diesel(sql_type = Nullable<Text>)]
    series: Option<String>,
    #[diesel(sql_type = Nullable<Float8>)]
    value: Option<f64>,
}

#[derive(Debug, Clone)]
enum SqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Float(f64),
    Timestamp(DateTime<Utc>),
    BigInt(i64),
}

impl SqlBindValue {
    fn apply<'a>(
        &self,
        query: diesel::query_builder::BoxedSqlQuery<'a, Pg, diesel::query_builder::SqlQuery>,
    ) -> diesel::query_builder::BoxedSqlQuery<'a, Pg, diesel::query_builder::SqlQuery> {
        use diesel::sql_types::{Array, Float8, Int8, Text, Timestamptz};
        match self {
            SqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            SqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            SqlBindValue::Float(value) => query.bind::<Float8, _>(*value),
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
            SqlBindValue::BigInt(value) => query.bind::<Int8, _>(*value),
        }
    }

    fn into_bind_param(self) -> BindParam {
        match self {
            SqlBindValue::Text(value) => BindParam::Text(value),
            SqlBindValue::TextArray(values) => BindParam::TextArray(values),
            SqlBindValue::Float(value) => BindParam::Float(value),
            SqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
            SqlBindValue::BigInt(value) => BindParam::Int(value),
        }
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut index = 1;
    for ch in sql.chars() {
        if ch == '?' {
            result.push('$');
            result.push_str(&index.to_string());
            index += 1;
        } else {
            result.push(ch);
        }
    }
    result
}
