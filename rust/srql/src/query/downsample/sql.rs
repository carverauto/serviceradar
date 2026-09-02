use super::{
    bind::SqlBindValue,
    fields::{
        agg_expr, flow_cagg_for_bucket, is_rate_agg, rate_bucket_combine, resolve_value_column,
        series_expr,
    },
    filters::filter_clause,
};
use crate::{
    error::{Result, ServiceError},
    parser::{DownsampleAgg, Entity, OrderDirection},
    query::{BindParam, QueryPlan},
    time::TimeRange,
};

/// Whether `limit:` should keep the newest buckets in the window instead of the oldest.
///
/// A chart always *renders* buckets oldest-first, so the returned rows are ordered
/// ascending no matter what. But when `limit:` is smaller than the number of buckets in
/// the range, something has to decide which end of the window survives -- and that is
/// exactly what `sort:time:desc` asks about. The ordering used to be hardcoded ascending
/// and `plan.order` was dropped on the floor, so `sort:time:desc limit:100` returned the
/// OLDEST 100 buckets: a 30-day chart at `bucket:5m` silently stopped two weeks back.
///
/// `sort:` on a downsample can only mean the bucket timestamp -- the projection is
/// (timestamp, series, value) and the other two are not orderable in a useful way -- so
/// the field name is not inspected, only the direction.
fn downsample_keeps_newest(plan: &QueryPlan) -> bool {
    plan.order
        .first()
        .is_some_and(|clause| matches!(clause.direction, OrderDirection::Desc))
}

/// Applies the ordering + `LIMIT`/`OFFSET` tail to an aggregated downsample body.
///
/// `body` must project exactly `(timestamp, series, value)` and end after its
/// `GROUP BY`. When the newest buckets are wanted, the body is truncated descending
/// inside a subquery and re-sorted ascending on the way out, so the caller gets the
/// requested end of the window in chart order. The `?` placeholders stay in the same
/// position relative to the `WHERE` binds either way, so `build_bind_values` is
/// unaffected.
fn finalize_downsample_sql(body: String, keeps_newest: bool) -> String {
    if keeps_newest {
        format!(
            "SELECT timestamp, series, value FROM (\n{body}\nORDER BY 1 DESC, 2 ASC NULLS FIRST\nLIMIT ? OFFSET ?\n) windowed\nORDER BY 1 ASC, 2 ASC NULLS FIRST"
        )
    } else {
        format!("{body}\nORDER BY 1 ASC, 2 ASC NULLS FIRST\nLIMIT ? OFFSET ?")
    }
}

pub(super) fn build_sql(plan: &QueryPlan) -> Result<String> {
    let downsample = plan.downsample.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("downsample requires bucket:<duration>".into())
    })?;

    // Flows route through a dedicated closed-vs-current UNION builder: materialized buckets
    // come from the pre-aggregated traffic CAGG and only the still-open bucket is read from
    // the raw hypertable. This keeps the sampling-rate-weighted throughput chart off the raw
    // full-table scan that was timing out (fj #33).
    if let Some(cagg_table) = flow_cagg_route(plan) {
        return build_flow_cagg_union_sql(downsample, cagg_table, downsample_keeps_newest(plan));
    }

    let use_hourly_cagg = super::super::should_route_plan_to_hourly_cagg(plan)
        && match plan.entity {
            // Flows CAGG routing is handled by `flow_cagg_route` above.
            Entity::Flows => false,
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
            ));
        }
    };

    // Flows never reach here with `use_hourly_cagg` (handled by `flow_cagg_route` above);
    // this path now only covers the metric-family CAGGs.
    let table = if use_hourly_cagg {
        super::super::cagg_table_for_entity(&plan.entity).unwrap_or(raw_table)
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
    let rate_partition_expr = rate_partition_expr(plan, &series_expr);
    let bucket_secs = downsample.bucket_seconds;

    let mut clauses = Vec::new();
    if use_hourly_cagg {
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
        // This handles SNMP counter metrics properly by calculating the rate of change per second.
        //
        // Counter-wrap awareness: a 32-bit Counter32 (ifInOctets/ifOutOctets) on a busy
        // 1 Gbps link wraps (2^32 bytes) every ~34s, often *inside* the poll interval. The
        // old `WHEN value < prev_value THEN NULL` rule dropped every wrapped sample, which
        // made busy links read as ~KB/s instead of hundreds of Mbps. We now add the counter
        // modulus on a decrease (value + 2^width - prev_value) so the real delta is recovered,
        // and only fall back to NULL when the decrease looks like a genuine counter reset
        // rather than a wrap. The modulus is chosen from the per-sample `counter_width`
        // column (see migration add_counter_width_to_timeseries_metrics): 64 -> 2^64,
        // 32 -> 2^32, and NULL/unknown -> a 32-bit heuristic (only when prev_value still fit
        // in 32 bits; otherwise the prior value could not have been a Counter32 so the
        // decrease is treated as a reset and dropped).
        let time_delta = format!("NULLIF(EXTRACT(EPOCH FROM ({ts_col} - prev_timestamp)), 0)");

        // Only the timeseries-family raw tables carry the `counter_width` column. Other
        // metric tables (cpu/memory/disk/process) keep the legacy drop-on-decrease behavior.
        let has_counter_width = matches!(
            plan.entity,
            Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics
        );

        let (counter_width_select, rate_case) = if has_counter_width {
            (
                r#",
    counter_width,
    CASE
      WHEN metadata->>'max_counter_rate_per_second' ~ '^[0-9]+(\.[0-9]+){0,1}$'
        THEN (metadata->>'max_counter_rate_per_second')::double precision
      ELSE NULL
    END AS max_rate_per_second"#
                    .to_string(),
                format!(
                    r#"CASE
      -- Monotonic increase (the common case): plain delta / elapsed seconds.
      WHEN {value_col} >= prev_value
        AND (
          max_rate_per_second IS NULL
          OR ({value_col} - prev_value) / {time_delta} <= max_rate_per_second
        )
        THEN ({value_col} - prev_value) / {time_delta}
      -- Decrease on a 64-bit (HC) counter: add the 2^64 modulus only when a
      -- producer-supplied plausibility ceiling rules it in.
      WHEN counter_width = 64
        AND max_rate_per_second IS NOT NULL
        AND ({value_col} + 18446744073709551616 - prev_value) / {time_delta} <= max_rate_per_second
        THEN ({value_col} + 18446744073709551616 - prev_value) / {time_delta}
      -- Decrease on an explicit 32-bit counter: add the 2^32 modulus, bounded
      -- by a producer-supplied ceiling when present and 2^32/s otherwise.
      WHEN counter_width = 32
        AND ({value_col} + 4294967296 - prev_value) / {time_delta} <= COALESCE(max_rate_per_second, 4294967296)
        THEN ({value_col} + 4294967296 - prev_value) / {time_delta}
      -- Unknown width (legacy rows): assume a 32-bit wrap only when the previous value
      -- still fit in 32 bits, otherwise treat the decrease as a genuine reset and drop it.
      WHEN prev_value < 4294967296
        AND ({value_col} + 4294967296 - prev_value) / {time_delta} <= COALESCE(max_rate_per_second, 4294967296)
        THEN ({value_col} + 4294967296 - prev_value) / {time_delta}
      ELSE NULL
    END"#
                ),
            )
        } else {
            (
                String::new(),
                format!(
                    r#"CASE
      -- Skip counter wraps/resets (when current < previous, counter wrapped or reset)
      WHEN {value_col} < prev_value THEN NULL
      -- Calculate rate: delta_value / delta_time_seconds
      ELSE ({value_col} - prev_value) / {time_delta}
    END"#
                ),
            )
        };

        let sql = format!(
            r#"WITH ordered_data AS (
  SELECT
    {ts_col},
    {series_expr} AS series,
    {value_col},
    LAG({value_col}) OVER (PARTITION BY {rate_partition_expr} ORDER BY {ts_col}) AS prev_value,
    LAG({ts_col}) OVER (PARTITION BY {rate_partition_expr} ORDER BY {ts_col}) AS prev_timestamp{counter_width_select}
  FROM {table}
  WHERE {where_clause}
),
rate_data AS (
  SELECT
    {ts_col} AS timestamp,
    series,
    {rate_case} AS rate_value
  FROM ordered_data
  WHERE prev_value IS NOT NULL  -- Skip first row which has no previous
)
SELECT
  to_timestamp(floor(extract(epoch from timestamp) / {bucket_secs}) * {bucket_secs}) AT TIME ZONE 'UTC' AS timestamp,
  series,
  {rate_combine}(rate_value) AS value
FROM rate_data
WHERE rate_value IS NOT NULL  -- Skip NULL rates from counter wraps
GROUP BY 1, 2"#,
            ts_col = ts_col,
            series_expr = series_expr,
            value_col = value_col,
            table = table,
            where_clause = where_clause,
            rate_partition_expr = rate_partition_expr,
            // AVG answers "the typical rate of one of these"; SUM answers "the
            // combined rate of all of them". They diverge exactly when a display
            // series collapses several underlying counters -- several
            // controllers each keeping their own counters for one RADIUS
            // server, where the fleet total is the sum and the average
            // understates it by the controller count.
            rate_combine = rate_bucket_combine(downsample.agg),
            bucket_secs = bucket_secs
        );
        let _ = time_range;
        return Ok(finalize_downsample_sql(sql, downsample_keeps_newest(plan)));
    }

    // Standard aggregation (non-rate). Flow CAGG aggregation (including COUNT(*) ->
    // SUM(flow_count)) is handled by the dedicated `build_flow_cagg_union_sql` path above.
    let agg_expr = agg_expr(downsample.agg, &value_col);

    // Use standard PostgreSQL floor-based bucketing instead of TimescaleDB's time_bucket
    // This floors the timestamp to the nearest bucket boundary
    let mut sql = format!(
        "SELECT to_timestamp(floor(extract(epoch from {ts_col}) / {bucket_secs}) * {bucket_secs}) AT TIME ZONE 'UTC' AS timestamp, {series_expr} AS series, {agg_expr} AS value\nFROM {table}\nWHERE ",
    );
    sql.push_str(&where_clause);
    sql.push_str("\nGROUP BY 1, 2");

    let _ = time_range;
    Ok(finalize_downsample_sql(sql, downsample_keeps_newest(plan)))
}

fn rate_partition_expr(plan: &QueryPlan, display_series_expr: &str) -> String {
    if matches!(
        plan.entity,
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics
    ) {
        "gateway_id, COALESCE(agent_id, ''), metric_type, metric_name, series_key".to_string()
    } else {
        display_series_expr.to_string()
    }
}

/// Returns the flow traffic CAGG table when a flows downsample plan can be served from a
/// pre-aggregated continuous aggregate.
///
/// Eligibility (strict shape): the entity is flows, the time range is past the hourly-CAGG
/// routing threshold, the bucket is at least the 5-minute CAGG resolution, the aggregation is
/// `sum`/`count`/`avg` over `bytes_total`/`packets_total` (or a bare `count(*)`), and there are
/// no dimension filters or series grouping — the traffic CAGGs only materialize
/// `(bucket, bytes_total, packets_total, flow_count)`, so any other dimension would be lossy.
fn flow_cagg_route(plan: &QueryPlan) -> Option<&'static str> {
    if !matches!(plan.entity, Entity::Flows) {
        return None;
    }
    if !super::super::should_route_plan_to_hourly_cagg(plan) {
        return None;
    }

    let downsample = plan.downsample.as_ref()?;

    let agg_ok = matches!(
        downsample.agg,
        DownsampleAgg::Sum | DownsampleAgg::Count | DownsampleAgg::Avg
    );
    let value_field_ok = matches!(
        downsample.value_field.as_deref(),
        None | Some("bytes_total") | Some("packets_total")
    );

    if cagg_safe_shape_strict(plan) && downsample.bucket_seconds >= 300 && agg_ok && value_field_ok
    {
        Some(flow_cagg_for_bucket(downsample.bucket_seconds))
    } else {
        None
    }
}

/// Builds the flows throughput downsample SQL that reads materialized buckets from the
/// pre-aggregated traffic CAGG and the single still-open bucket from the raw hypertable.
///
/// The flow traffic CAGGs (`ocsf_network_activity_5m_traffic`, `flow_traffic_1h`,
/// `flow_traffic_1d`) materialize `bytes_total`/`packets_total` as the sampling-rate-weighted
/// SUM and `flow_count` as the row COUNT (see migration
/// `20260621143000_rebuild_flow_caggs_with_sampling_rate`). A chart
/// `avg(value * sampling_rate)` is therefore reconstructed as
/// `SUM(weighted_sum) / SUM(flow_count)`; `sum` keeps `SUM(weighted_sum)` and `count(*)`
/// becomes `SUM(flow_count)`.
///
/// These CAGGs are `materialized_only` (no TimescaleDB real-time union) and lag real time by
/// the continuous-aggregate `end_offset` + schedule, so the current open chart bucket is read
/// from the raw hypertable and UNION-ed with the materialized closed buckets — mirroring the
/// closed-vs-current split used by web-ng SecurityTrend (#4263). The raw scan is bounded to a
/// single open bucket, so it stays cheap instead of scanning the full time range.
fn build_flow_cagg_union_sql(
    downsample: &crate::parser::DownsampleSpec,
    cagg_table: &str,
    keeps_newest: bool,
) -> Result<String> {
    let bucket_secs = downsample.bucket_seconds;
    let field = downsample.value_field.as_deref();

    // CAGG column already holds the sampling-rate-weighted SUM for bytes/packets.
    let cagg_value_col = resolve_value_column(Entity::Flows, field, true)?;
    // Raw per-flow sampling-rate-weighted value, matching the CAGG materialization exactly.
    let raw_value_expr = resolve_value_column(Entity::Flows, field, false)?;

    let outer_value = match downsample.agg {
        DownsampleAgg::Sum => "SUM(weighted_sum)".to_string(),
        DownsampleAgg::Count => "SUM(cnt)".to_string(),
        DownsampleAgg::Avg => "SUM(weighted_sum) / NULLIF(SUM(cnt), 0)".to_string(),
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "flow CAGG routing does not support {other:?} aggregation"
            )));
        }
    };

    // Start of the current chart bucket; materialized buckets are strictly before it.
    let boundary =
        format!("to_timestamp(floor(extract(epoch from now()) / {bucket_secs}) * {bucket_secs})");

    // Placeholders in order: CAGG `bucket >= ?` (start), CAGG `bucket <= ?` (end),
    // raw `time <= ?` (end), then LIMIT/OFFSET. See `build_bind_values`.
    let sql = format!(
        "SELECT to_timestamp(floor(extract(epoch from bucket) / {bucket_secs}) * {bucket_secs}) AT TIME ZONE 'UTC' AS timestamp, series, {outer_value} AS value\n\
FROM (\n\
SELECT bucket, NULL::text AS series, {cagg_value_col}::double precision AS weighted_sum, flow_count::double precision AS cnt\n\
FROM {cagg_table}\n\
WHERE bucket >= ? AND bucket <= ? AND bucket < {boundary}\n\
UNION ALL\n\
SELECT to_timestamp(floor(extract(epoch from time) / {bucket_secs}) * {bucket_secs}) AS bucket, NULL::text AS series, SUM({raw_value_expr}) AS weighted_sum, COUNT(*)::double precision AS cnt\n\
FROM ocsf_network_activity\n\
WHERE time >= {boundary} AND time <= ?\n\
GROUP BY 1, 2\n\
) combined\n\
GROUP BY 1, 2",
    );

    Ok(finalize_downsample_sql(sql, keeps_newest))
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

    // The flows CAGG-union SQL references `end` a second time (CAGG upper bound + raw-current
    // upper bound) and never carries filter/type binds (strict CAGG shape).
    if flow_cagg_route(plan).is_some() {
        binds.push(SqlBindValue::Timestamp(*end));
        binds.push(SqlBindValue::BigInt(plan.limit));
        binds.push(SqlBindValue::BigInt(plan.offset));
        return Ok(binds);
    }

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

/// Rewrites `?` bind placeholders to Postgres `$1..$N`, skipping any `?` that
/// occurs inside a single-quoted SQL string literal (e.g. a `?` regex
/// quantifier such as `~ '^[0-9]+(\.[0-9]+)?$'`). Rewriting a literal's `?`
/// shifts every real bind by one and Postgres rejects the query with 42P18
/// "could not determine data type of parameter $1" (fj #4408).
///
/// SQL escapes a quote inside a literal by doubling it (`''`); a doubled quote
/// toggles the in-literal state twice, so simple toggling tracks it correctly.
pub(super) fn rewrite_placeholders(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut index = 1;
    let mut in_literal = false;
    for ch in sql.chars() {
        match ch {
            '\'' => {
                in_literal = !in_literal;
                result.push(ch);
            }
            '?' if !in_literal => {
                result.push('$');
                result.push_str(&index.to_string());
                index += 1;
            }
            _ => result.push(ch),
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::rewrite_placeholders;

    #[test]
    fn rewrite_placeholders_numbers_binds_outside_literals() {
        assert_eq!(
            rewrite_placeholders("SELECT 1 WHERE a >= ? AND b <= ? LIMIT ? OFFSET ?"),
            "SELECT 1 WHERE a >= $1 AND b <= $2 LIMIT $3 OFFSET $4"
        );
    }

    #[test]
    fn rewrite_placeholders_skips_question_marks_inside_string_literals() {
        let sql = r"SELECT x ~ '^[0-9]+(\.[0-9]+)?$' AS ok FROM t WHERE a = ? AND b = ?";
        assert_eq!(
            rewrite_placeholders(sql),
            r"SELECT x ~ '^[0-9]+(\.[0-9]+)?$' AS ok FROM t WHERE a = $1 AND b = $2"
        );
    }

    #[test]
    fn rewrite_placeholders_handles_escaped_quote_doubling() {
        // `''` inside a literal is an escaped quote, not a literal boundary:
        // the `?` after it is still inside the string and must not be rewritten.
        let sql = "SELECT 'what''s this?' AS q WHERE a = ? AND b = 'x' AND c = ?";
        assert_eq!(
            rewrite_placeholders(sql),
            "SELECT 'what''s this?' AS q WHERE a = $1 AND b = 'x' AND c = $2"
        );
    }
}
