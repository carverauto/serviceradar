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

    let use_hourly_cagg = super::super::should_route_plan_to_hourly_cagg(plan)
        && match plan.entity {
            Entity::Flows => {
                cagg_safe_shape_strict(plan)
                    && downsample.bucket_seconds >= 300
                    && matches!(downsample.agg, DownsampleAgg::Sum | DownsampleAgg::Count)
                    && matches!(
                        downsample.value_field.as_deref(),
                        None | Some("bytes_total") | Some("packets_total")
                    )
            }
            // The timeseries family CAGG (`timeseries_metrics_hourly`) groups by
            // (bucket, device_id, metric_type, metric_name) and stores avg/min/max_value.
            // A device-filtered chart request is safe to route as long as every filter and
            // the optional series grouping only reference those CAGG group keys, the agg has a
            // pre-materialized column, and the bucket is hourly-or-coarser (the CAGG resolution).
            Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => {
                downsample.bucket_seconds >= 3600
                    && matches!(
                        downsample.agg,
                        DownsampleAgg::Avg | DownsampleAgg::Min | DownsampleAgg::Max
                    )
                    && timeseries_cagg_safe_shape(plan)
            }
            // Other metric CAGGs (cpu/memory/disk/process) keep the strict no-filter gate.
            _ => cagg_safe_shape_strict(plan) && matches!(downsample.agg, DownsampleAgg::Avg),
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

    // The timeseries CAGG materializes avg/min/max separately. For MIN/MAX chart aggs we must
    // read the matching pre-aggregated column so MIN(min_value)/MAX(max_value) stays exact over
    // multi-hour buckets (min-of-mins / max-of-maxes). AVG keeps avg_value (mean-of-means, the
    // CAGG's existing resolution). `resolve_value_column` defaults to avg_value for this CAGG.
    let value_col = if use_hourly_cagg
        && matches!(
            plan.entity,
            Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics
        ) {
        match downsample.agg {
            DownsampleAgg::Min => "min_value".to_string(),
            DownsampleAgg::Max => "max_value".to_string(),
            _ => value_col,
        }
    } else {
        value_col
    };

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

/// Strict CAGG-safety: no filters and no series grouping. Used for entities whose
/// CAGG group keys we have not column-checked here (cpu/memory/disk/process, flows).
fn cagg_safe_shape_strict(plan: &QueryPlan) -> bool {
    let series_empty = plan
        .downsample
        .as_ref()
        .and_then(|d| d.series.as_deref())
        .unwrap_or("")
        .trim()
        .is_empty();
    plan.filters.is_empty() && series_empty
}

/// CAGG group keys present on `platform.timeseries_metrics_hourly`. Any filter or series
/// grouping that references a column NOT in this set would change the result if served from
/// the CAGG (the column was collapsed away during materialization), so such queries must
/// stay on the raw hypertable.
fn timeseries_field_is_cagg_safe(field: &str) -> bool {
    matches!(
        field.trim().to_ascii_lowercase().as_str(),
        "device_id" | "metric_type" | "metric_name"
    )
}

/// True when a timeseries-family downsample plan only touches CAGG group keys.
fn timeseries_cagg_safe_shape(plan: &QueryPlan) -> bool {
    // Every filter must be on a CAGG group key. Filters on agent_id/gateway_id/partition/
    // target_device_ip/if_index/value would be lossy against the rolled-up CAGG.
    if !plan
        .filters
        .iter()
        .all(|filter| timeseries_field_is_cagg_safe(&filter.field))
    {
        return false;
    }

    // The optional series grouping (e.g. `series:device_id`) must also be a CAGG group key.
    // `series:core_id` (tags->>'core_id'), `series:if_index`, etc. are not materialized.
    match plan.downsample.as_ref().and_then(|d| d.series.as_deref()) {
        Some(series) if !series.trim().is_empty() => timeseries_field_is_cagg_safe(series),
        _ => true,
    }
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
