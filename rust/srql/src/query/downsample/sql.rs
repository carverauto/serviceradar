use super::{
    bind::SqlBindValue,
    fields::{agg_expr, flow_cagg_for_bucket, is_rate_agg, resolve_value_column, series_expr},
    filters::filter_clause,
};
use crate::{
    error::{Result, ServiceError},
    parser::{DownsampleAgg, Entity},
    query::{BindParam, QueryPlan},
    time::TimeRange,
};

pub(super) fn build_sql(plan: &QueryPlan) -> Result<String> {
    let downsample = plan.downsample.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("downsample requires bucket:<duration>".into())
    })?;

    let cagg_safe_shape =
        plan.filters.is_empty() && downsample.series.as_deref().unwrap_or("").trim().is_empty();
    let use_hourly_cagg = super::super::should_route_plan_to_hourly_cagg(plan)
        && cagg_safe_shape
        && match plan.entity {
            Entity::Flows => {
                downsample.bucket_seconds >= 300
                    && matches!(downsample.agg, DownsampleAgg::Sum | DownsampleAgg::Count)
                    && matches!(
                        downsample.value_field.as_deref(),
                        None | Some("bytes_total") | Some("packets_total")
                    )
            }
            _ => matches!(downsample.agg, DownsampleAgg::Avg),
        };

    let (raw_table, raw_ts_col, forced_metric_type) = match plan.entity {
        Entity::TimeseriesMetrics => ("timeseries_metrics", "timestamp", None),
        Entity::SnmpMetrics => ("timeseries_metrics", "timestamp", Some("snmp")),
        Entity::RperfMetrics => ("timeseries_metrics", "timestamp", Some("rperf")),
        Entity::CpuMetrics => ("cpu_metrics", "timestamp", None),
        Entity::MemoryMetrics => ("memory_metrics", "timestamp", None),
        Entity::DiskMetrics => ("disk_metrics", "timestamp", None),
        Entity::ProcessMetrics => ("process_metrics", "timestamp", None),
        Entity::Flows => ("ocsf_network_activity", "time", None),
        _ => {
            return Err(ServiceError::InvalidRequest(
                "downsample is only supported for metric entities and flows".into(),
            ))
        }
    };

    let table = if use_hourly_cagg {
        if matches!(plan.entity, Entity::Flows) {
            flow_cagg_for_bucket(downsample.bucket_seconds)
        } else {
            super::super::cagg_table_for_entity(&plan.entity).unwrap_or(raw_table)
        }
    } else {
        raw_table
    };
    let ts_col = if use_hourly_cagg {
        "bucket"
    } else {
        raw_ts_col
    };

    let value_col = resolve_value_column(
        plan.entity.clone(),
        downsample.value_field.as_deref(),
        use_hourly_cagg,
    )?;

    let time_range = plan.time_range.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("downsample queries require time:<range>".into())
    })?;

    let series_expr = series_expr(plan, table)?;
    let bucket_secs = downsample.bucket_seconds;

    let mut clauses = Vec::new();
    if use_hourly_cagg && !matches!(plan.entity, Entity::Flows) {
        clauses.push(super::super::hourly_cagg_lower_bound_clause(ts_col));
        clauses.push(super::super::hourly_cagg_upper_bound_clause(ts_col));
    } else {
        clauses.push(format!("{ts_col} >= ?"));
        clauses.push(format!("{ts_col} <= ?"));
    }

    if let Some(metric_type) = forced_metric_type {
        clauses.push("metric_type = ?".to_string());
        let _ = metric_type;
    }

    for filter in &plan.filters {
        let (clause, _) = filter_clause(&plan.entity, table, filter)?;
        clauses.push(clause);
    }

    let where_clause = clauses.join(" AND ");

    // For rate aggregation, use a CTE with window functions to calculate rate of change
    if is_rate_agg(downsample.agg) {
        // Rate calculation: (current_value - previous_value) / time_delta_seconds
        // This handles SNMP counter metrics properly by calculating the rate of change per second
        // We skip rows where value < prev_value (counter wrap/reset) to avoid negative rates
        let sql = format!(
            r#"WITH ordered_data AS (
  SELECT
    {ts_col},
    {series_expr} AS series,
    {value_col},
    LAG({value_col}) OVER (PARTITION BY {series_expr} ORDER BY {ts_col}) AS prev_value,
    LAG({ts_col}) OVER (PARTITION BY {series_expr} ORDER BY {ts_col}) AS prev_timestamp
  FROM {table}
  WHERE {where_clause}
),
rate_data AS (
  SELECT
    {ts_col} AS timestamp,
    series,
    CASE
      -- Skip counter wraps/resets (when current < previous, counter wrapped or reset)
      WHEN {value_col} < prev_value THEN NULL
      -- Calculate rate: delta_value / delta_time_seconds
      ELSE ({value_col} - prev_value) / NULLIF(EXTRACT(EPOCH FROM ({ts_col} - prev_timestamp)), 0)
    END AS rate_value
  FROM ordered_data
  WHERE prev_value IS NOT NULL  -- Skip first row which has no previous
)
SELECT
  to_timestamp(floor(extract(epoch from timestamp) / {bucket_secs}) * {bucket_secs}) AT TIME ZONE 'UTC' AS timestamp,
  series,
  AVG(rate_value) AS value
FROM rate_data
WHERE rate_value IS NOT NULL  -- Skip NULL rates from counter wraps
GROUP BY 1, 2
ORDER BY 1 ASC, 2 ASC NULLS FIRST
LIMIT ? OFFSET ?"#,
            ts_col = ts_col,
            series_expr = series_expr,
            value_col = value_col,
            table = table,
            where_clause = where_clause,
            bucket_secs = bucket_secs
        );
        let _ = time_range;
        return Ok(sql);
    }

    // Standard aggregation (non-rate)
    // For flow CAGGs, COUNT(*) must become SUM(flow_count) since rows are pre-aggregated.
    let agg_expr = if use_hourly_cagg
        && matches!(plan.entity, Entity::Flows)
        && matches!(downsample.agg, DownsampleAgg::Count)
    {
        "SUM(flow_count)".to_string()
    } else {
        agg_expr(downsample.agg, &value_col)
    };

    // Use standard PostgreSQL floor-based bucketing instead of TimescaleDB's time_bucket
    // This floors the timestamp to the nearest bucket boundary
    let mut sql = format!(
        "SELECT to_timestamp(floor(extract(epoch from {ts_col}) / {bucket_secs}) * {bucket_secs}) AT TIME ZONE 'UTC' AS timestamp, {series_expr} AS series, {agg_expr} AS value\nFROM {table}\nWHERE ",
    );
    sql.push_str(&where_clause);
    sql.push_str("\nGROUP BY 1, 2\nORDER BY 1 ASC, 2 ASC NULLS FIRST\nLIMIT ? OFFSET ?");

    let _ = time_range;
    Ok(sql)
}

pub(super) fn build_params(plan: &QueryPlan) -> Result<Vec<BindParam>> {
    Ok(build_bind_values(plan)?
        .into_iter()
        .map(|value| value.into_bind_param())
        .collect())
}

pub(super) fn build_bind_values(plan: &QueryPlan) -> Result<Vec<SqlBindValue>> {
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

pub(super) fn rewrite_placeholders(sql: &str) -> String {
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
