use super::*;

#[test]
fn cagg_routing_threshold_boundary() {
    let now = chrono::Utc::now();
    let under = TimeRange {
        start: now - ChronoDuration::hours(5) - ChronoDuration::minutes(59),
        end: now,
    };
    let at = TimeRange {
        start: now - ChronoDuration::hours(6),
        end: now,
    };

    assert!(!should_route_to_hourly_cagg(
        &Entity::CpuMetrics,
        Some(&under),
        true,
        false
    ));
    assert!(should_route_to_hourly_cagg(
        &Entity::CpuMetrics,
        Some(&at),
        true,
        false
    ));
}

#[test]
fn aggregate_metric_query_allows_one_year_timeframe() {
    let config = test_config();
    let query = "in:cpu_metrics time:last_1y stats:avg(usage_percent) as avg_usage";
    let ast = parser::parse(query).expect("query should parse");
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let plan = build_query_plan(&config, &request, ast)
        .expect("stats metric query should allow extended range");
    let range = plan.time_range.expect("time range should exist");
    assert!(
        range.end.signed_duration_since(range.start) >= ChronoDuration::days(365),
        "expected ~1 year range, got: {:?}",
        range.end.signed_duration_since(range.start)
    );
}

#[test]
fn plain_metric_query_still_rejects_one_year_timeframe() {
    let config = test_config();
    let query = "in:cpu_metrics time:last_1y";
    let ast = parser::parse(query).expect("query should parse");
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let err = build_query_plan(&config, &request, ast)
        .expect_err("plain query should still enforce 90 day limit");
    assert!(
        err.to_string().contains("cannot exceed 90 days"),
        "unexpected error: {err}"
    );
}

#[test]
fn cagg_column_mappings_cover_metric_entities() {
    assert_eq!(
        cagg_column_for_entity(&Entity::CpuMetrics, "avg", "usage_percent"),
        Some("avg_usage_percent")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::MemoryMetrics, "avg", "used_bytes"),
        Some("avg_used_bytes")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::DiskMetrics, "max", "usage_percent"),
        Some("max_usage_percent")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::ProcessMetrics, "avg", "cpu_usage"),
        Some("avg_cpu_usage")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::TimeseriesMetrics, "min", "value"),
        Some("min_value")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::TimeseriesMetrics, "sum", "value"),
        None
    );
}

#[test]
fn cpu_stats_without_group_by_translates_and_routes_to_cagg() {
    let config = test_config();
    let request = QueryRequest {
        query: "in:cpu_metrics time:last_7d stats:avg(usage_percent) as avg_usage".into(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response =
        translate_request(&config, request).expect("ungrouped cpu stats should translate");
    let sql = response.sql.to_lowercase();
    assert!(
        sql.contains("from cpu_metrics_hourly"),
        "expected CAGG source for large-window stats query, got: {}",
        response.sql
    );
    assert!(
        sql.contains("bucket >= time_bucket('1 hour', $1::timestamptz)")
            && sql.contains("bucket < time_bucket('1 hour', $2::timestamptz) + interval '1 hour'"),
        "expected CAGG bucket-overlap bounds for partial windows, got: {}",
        response.sql
    );
    assert!(
        !sql.contains("group by device_id"),
        "ungrouped query should not force device grouping, got: {}",
        response.sql
    );
}

#[test]
fn cpu_stats_without_alias_translates_and_routes_to_cagg() {
    let config = test_config();
    let request = QueryRequest {
        query: "in:cpu_metrics time:last_7d stats:avg(usage_percent)".into(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response =
        translate_request(&config, request).expect("alias-less cpu stats should translate");
    let sql = response.sql.to_lowercase();
    assert!(
        sql.contains("from cpu_metrics_hourly"),
        "expected CAGG source for large-window stats query, got: {}",
        response.sql
    );
    assert!(
        !sql.contains("group by device_id"),
        "ungrouped query should not force device grouping, got: {}",
        response.sql
    );
}
