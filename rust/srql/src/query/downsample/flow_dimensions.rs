//! Dimension-preserving flow SUMs from hourly aggregates, with raw window edges.

use super::{fields::resolve_value_column, fields::series_expr, filters::filter_clause};
use crate::{
    error::Result,
    parser::{DownsampleAgg, Entity, Filter, FilterOp, FilterValue},
    query::QueryPlan,
};

/// These aggregates collapse NULL dimensions into sentinels. Only positive
/// equality/list filters excluding those sentinels preserve the raw predicate.
pub(super) fn route(plan: &QueryPlan) -> Option<&'static str> {
    if !matches!(plan.entity, Entity::Flows)
        || !super::super::should_route_plan_to_hourly_cagg(plan)
    {
        return None;
    }

    let spec = plan.downsample.as_ref()?;
    if spec.bucket_seconds < 3600
        || spec.bucket_seconds % 3600 != 0
        || !matches!(spec.agg, DownsampleAgg::Sum)
        || !matches!(
            spec.value_field.as_deref(),
            None | Some("bytes_total") | Some("packets_total")
        )
    {
        return None;
    }

    let column = plan
        .filters
        .first()
        .and_then(|filter| dimension(&filter.field))
        .or_else(|| spec.series.as_deref().and_then(dimension))?;
    if plan.filters.is_empty() && column != "protocol_group" {
        return None;
    }
    if !plan
        .filters
        .iter()
        .all(|filter| safe_filter(filter, column))
    {
        return None;
    }
    if let Some(series) = spec.series.as_deref().filter(|value| !value.is_empty())
        && dimension(series) != Some(column)
    {
        return None;
    }

    match column {
        "dst_endpoint_port" => Some("ocsf_network_activity_hourly_ports"),
        "src_endpoint_ip" => Some("ocsf_network_activity_hourly_talkers"),
        "protocol_group" => Some("ocsf_network_activity_hourly_proto"),
        _ => None,
    }
}

fn dimension(field: &str) -> Option<&'static str> {
    match field {
        "dst_port" | "dst_endpoint_port" => Some("dst_endpoint_port"),
        "src_ip" | "src_endpoint_ip" => Some("src_endpoint_ip"),
        "protocol_group" | "proto_group" => Some("protocol_group"),
        _ => None,
    }
}

fn safe_filter(filter: &Filter, column: &str) -> bool {
    if dimension(&filter.field) != Some(column) {
        return false;
    }
    match (&filter.op, &filter.value) {
        (FilterOp::Eq, FilterValue::Scalar(value)) => safe_value(value, column),
        (FilterOp::In, FilterValue::List(values)) => {
            !values.is_empty() && values.iter().all(|value| safe_value(value, column))
        }
        _ => false,
    }
}

fn safe_value(value: &str, column: &str) -> bool {
    match column {
        "dst_endpoint_port" => value.parse::<u16>().is_ok_and(|port| port != 0),
        "src_endpoint_ip" => value.parse::<std::net::IpAddr>().is_ok(),
        // NULL and the aggregate's zero sentinel both belong to "other".
        "protocol_group" => matches!(value, "tcp" | "udp" | "other"),
        _ => false,
    }
}

pub(super) fn build_body(plan: &QueryPlan, table: &str) -> Result<String> {
    let spec = plan.downsample.as_ref().expect("route requires downsample");
    let bucket_secs = spec.bucket_seconds;
    let cagg_value = resolve_value_column(Entity::Flows, spec.value_field.as_deref(), true)?;
    let raw_value = resolve_value_column(Entity::Flows, spec.value_field.as_deref(), false)?;
    let series = series_expr(plan, table)?;
    let clauses = plan
        .filters
        .iter()
        .map(|filter| filter_clause(&Entity::Flows, table, filter).map(|(sql, _)| sql))
        .collect::<Result<Vec<_>>>()?
        .join(" AND ");
    let filters = if clauses.is_empty() { "TRUE" } else { &clauses };

    // Bounds are across the aggregate, not the selected dimension: an absent
    // port/talker is not evidence that materialization stopped. Empty aggregates
    // use raw coverage for the entire requested range. Strictly disjoint bounds
    // preserve partial first/last hours and include samples exactly at end_at.
    // Inline the bounds so Timescale can prune chunks and index both raw edges.
    Ok(format!(
        "WITH requested_window AS (\n\
SELECT ?::timestamptz AS start_at, ?::timestamptz AS end_at\n\
), bounds AS NOT MATERIALIZED (\n\
SELECT start_at, end_at,\n\
  GREATEST(date_trunc('hour', start_at, 'UTC') + CASE WHEN start_at = date_trunc('hour', start_at, 'UTC') THEN INTERVAL '0 hours' ELSE INTERVAL '1 hour' END, COALESCE((SELECT MIN(bucket) FROM {table}), 'infinity'::timestamptz)) AS rollup_start,\n\
  LEAST(date_trunc('hour', end_at, 'UTC'), COALESCE((SELECT MAX(bucket) + INTERVAL '1 hour' FROM {table}), '-infinity'::timestamptz)) AS rollup_end\n\
FROM requested_window\n\
)\n\
SELECT to_timestamp(floor(extract(epoch from bucket) / {bucket_secs}) * {bucket_secs}) AT TIME ZONE 'UTC' AS timestamp, series, SUM(weighted_sum) AS value\n\
FROM (\n\
SELECT bucket, {series} AS series, {cagg_value}::double precision AS weighted_sum\n\
FROM {table} CROSS JOIN bounds\n\
WHERE bucket >= rollup_start AND bucket < rollup_end AND {filters}\n\
UNION ALL\n\
SELECT to_timestamp(floor(extract(epoch from time) / {bucket_secs}) * {bucket_secs}) AS bucket, {series} AS series, SUM({raw_value}) AS weighted_sum\n\
FROM ocsf_network_activity CROSS JOIN bounds\n\
WHERE time >= start_at AND time <= end_at AND (time < rollup_start OR time >= rollup_end) AND {filters}\n\
GROUP BY 1, 2\n\
) combined\n\
GROUP BY 1, 2"
    ))
}

#[cfg(test)]
mod tests {
    use super::route;
    use crate::{
        config::AppConfig,
        parser,
        query::{
            QueryPlan, QueryRequest, SqlDialect, build_query_plan, downsample::to_sql_and_params,
        },
    };
    use serde_json::json;

    fn plan(query: &str) -> QueryPlan {
        let request = QueryRequest {
            query: query.into(),
            limit: None,
            cursor: None,
            direction: Default::default(),
            mode: None,
        };
        build_query_plan(
            &AppConfig::embedded(String::new()),
            &request,
            parser::parse(query).unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn flow_dimension_visible_stack_queries_use_weighted_hourly_sums() {
        for (time, bucket) in [("last_7d", "120m"), ("last_30d", "720m")] {
            for (filter, table) in [
                ("dst_port:443", "ocsf_network_activity_hourly_ports"),
                ("src_ip:192.0.2.8", "ocsf_network_activity_hourly_talkers"),
            ] {
                for value in ["bytes_total", "packets_total"] {
                    let plan = plan(&format!(
                        "in:flows time:{time} {filter} bucket:{bucket} agg:sum value_field:{value} limit:120"
                    ));
                    assert_eq!(route(&plan), Some(table));
                    let (sql, params) = to_sql_and_params(&plan).unwrap();
                    assert!(
                        sql.contains(&format!("FROM {table} CROSS JOIN bounds")),
                        "{sql}"
                    );
                    assert!(sql.contains(&format!("{value}::double precision AS weighted_sum")));
                    assert!(sql.contains(&format!("SUM(({value}::double precision * GREATEST(COALESCE(sampling_rate, 1), 1)::double precision))")));
                    assert!(sql.contains("SUM(weighted_sum) AS value"));
                    assert_eq!(params.len(), 6);
                }
            }
        }
    }

    #[test]
    fn flow_dimension_bounds_preserve_partial_hours_and_empty_aggregate_fallback() {
        let plan = plan(
            "in:flows time:[2025-01-01T00:17:00Z,2025-01-08T02:43:00Z] dst_port:443 bucket:120m agg:sum limit:120",
        );
        let (sql, params) = to_sql_and_params(&plan).unwrap();
        assert!(sql.contains("start_at = date_trunc('hour', start_at, 'UTC')"));
        assert!(sql.contains("bounds AS NOT MATERIALIZED"));
        assert!(sql.contains("SELECT MIN(bucket) FROM ocsf_network_activity_hourly_ports"));
        assert!(sql.contains("'infinity'::timestamptz"));
        assert!(sql.contains("MAX(bucket) + INTERVAL '1 hour'"));
        assert!(sql.contains("'-infinity'::timestamptz"));
        assert!(sql.contains("LEAST(date_trunc('hour', end_at, 'UTC')"));
        assert!(sql.contains("bucket >= rollup_start AND bucket < rollup_end"));
        assert!(sql.contains(
            "time >= start_at AND time <= end_at AND (time < rollup_start OR time >= rollup_end)"
        ));
        assert_eq!(
            serde_json::to_value(&params[0..2]).unwrap(),
            json!([
                {"t":"timestamptz", "v":"2025-01-01T00:17:00+00:00"},
                {"t":"timestamptz", "v":"2025-01-08T02:43:00+00:00"}
            ])
        );
    }

    #[test]
    fn flow_dimension_lists_and_series_preserve_typed_bind_order_and_newest_limit() {
        let mut plan = plan(
            "in:flows time:last_7d dst_port:(443,8443) dst_endpoint_port:443 series:dst_port bucket:120m agg:sum sort:time:desc limit:7",
        );
        plan.offset = 2;
        let (sql, params) = to_sql_and_params(&plan).unwrap();
        assert_eq!(
            sql.matches("coalesce(dst_endpoint_port::text, '') AS series")
                .count(),
            2
        );
        assert!(sql.contains("dst_endpoint_port = ANY($3) AND dst_endpoint_port = $4"));
        assert!(sql.contains("dst_endpoint_port = ANY($5) AND dst_endpoint_port = $6"));
        assert!(sql.contains("ORDER BY 1 DESC, 2 ASC NULLS FIRST\nLIMIT $7 OFFSET $8"));
        assert!(sql.ends_with("ORDER BY 1 ASC, 2 ASC NULLS FIRST"));
        assert_eq!(
            serde_json::to_value(&params[2..]).unwrap(),
            json!([
                {"t":"int_array", "v":[443,8443]}, {"t":"int", "v":443},
                {"t":"int_array", "v":[443,8443]}, {"t":"int", "v":443},
                {"t":"int", "v":7}, {"t":"int", "v":2}
            ])
        );

        let plan = self::plan(
            "in:flows time:last_7d src_ip:(192.0.2.8,2001:db8::8) series:src_endpoint_ip bucket:120m agg:sum limit:120",
        );
        let (sql, params) = to_sql_and_params(&plan).unwrap();
        assert_eq!(
            sql.matches("coalesce(src_endpoint_ip, '') AS series")
                .count(),
            2
        );
        assert_eq!(
            serde_json::to_value(&params[2..4]).unwrap(),
            json!([
                {"t":"text_array", "v":["192.0.2.8","2001:db8::8"]},
                {"t":"text_array", "v":["192.0.2.8","2001:db8::8"]}
            ])
        );
    }

    #[test]
    fn flow_dimension_unsafe_filters_and_unsupported_shapes_stay_raw() {
        for extra in [
            "dst_port:0",
            "dst_port:(0,443)",
            "!dst_port:443",
            "src_ip:Unknown",
            "src_ip:(192.0.2.8,Unknown)",
            "src_ip:192.0.2.%",
            "dst_port:443 src_ip:192.0.2.8",
            "dst_port:443 proto:6",
            "dst_port:443 series:src_ip",
            "dst_port:443 value_field:bytes_in",
        ] {
            let plan = plan(&format!(
                "in:flows time:last_7d bucket:120m agg:sum {extra}"
            ));
            assert_eq!(route(&plan), None, "unsafe shape: {extra}");
            let (sql, _) = to_sql_and_params(&plan).unwrap();
            assert!(
                !sql.contains("hourly_ports") && !sql.contains("hourly_talkers"),
                "{extra}: {sql}"
            );
        }

        for shape in [
            "time:last_1h bucket:1h agg:sum",
            "time:last_7d bucket:90m agg:sum",
            "time:last_7d bucket:120m agg:avg",
            "time:last_7d bucket:120m agg:count",
        ] {
            assert_eq!(
                route(&plan(&format!("in:flows dst_port:443 {shape}"))),
                None
            );
        }
    }

    #[test]
    fn flow_dimension_duckdb_never_reads_postgres_aggregates() {
        for filter in ["dst_port:443", "src_ip:192.0.2.8"] {
            let mut plan = plan(&format!(
                "in:flows time:last_30d {filter} bucket:720m agg:sum"
            ));
            plan.dialect = SqlDialect::Duckdb;
            assert_eq!(route(&plan), None);
            let (sql, _) = to_sql_and_params(&plan).unwrap();
            assert!(sql.contains("FROM ocsf_network_activity\n"));
            assert!(!sql.contains("hourly_") && !sql.contains("rollup_"));
        }
    }
}
