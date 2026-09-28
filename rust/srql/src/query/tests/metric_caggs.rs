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
        &Entity::TimeseriesMetrics,
        Some(&under),
        true,
        false,
        168
    ));
    assert!(should_route_to_hourly_cagg(
        &Entity::TimeseriesMetrics,
        Some(&at),
        true,
        false,
        168
    ));
}

#[test]
fn cagg_routes_short_window_beyond_raw_retention() {
    // #4514: a sub-threshold window that starts before the raw tables'
    // retention horizon must still read the rollup. The raw hypertable has
    // already dropped every row in that window, so the span heuristic alone
    // would answer from an empty source.
    let now = chrono::Utc::now();
    let beyond = TimeRange {
        start: now - ChronoDuration::days(10),
        end: now - ChronoDuration::days(10) + ChronoDuration::hours(3),
    };

    assert!(should_route_to_hourly_cagg(
        &Entity::TimeseriesMetrics,
        Some(&beyond),
        true,
        false,
        168
    ));
}

#[test]
fn cagg_keeps_span_gate_inside_raw_retention() {
    let now = chrono::Utc::now();
    let inside = TimeRange {
        start: now - ChronoDuration::days(5),
        end: now - ChronoDuration::days(5) + ChronoDuration::hours(3),
    };

    assert!(!should_route_to_hourly_cagg(
        &Entity::TimeseriesMetrics,
        Some(&inside),
        true,
        false,
        168
    ));
}

#[test]
fn cagg_retention_arm_honors_configured_horizon() {
    let now = chrono::Utc::now();
    let straddling = TimeRange {
        start: now - ChronoDuration::days(6),
        end: now - ChronoDuration::days(6) + ChronoDuration::hours(3),
    };

    assert!(!should_route_to_hourly_cagg(
        &Entity::TimeseriesMetrics,
        Some(&straddling),
        true,
        false,
        144
    ));
}

#[test]
fn short_old_timeseries_downsample_translates_to_cagg_source() {
    let config = test_config();
    let start = chrono::Utc::now() - ChronoDuration::days(10);
    let end = start + ChronoDuration::hours(3);
    let query = format!(
        "in:timeseries_metrics metric_type:snmp metric_name:ifInOctets time:\"[{},{}]\" bucket:1h agg:avg",
        start.format("%Y-%m-%dT%H:%M:%SZ"),
        end.format("%Y-%m-%dT%H:%M:%SZ")
    );
    let request = QueryRequest {
        query,
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
        permitted_signals: None,
    };

    let response =
        translate_request(&config, request).expect("old short downsample should translate");
    assert!(
        response
            .sql
            .to_lowercase()
            .contains("from timeseries_metrics_hourly"),
        "expected CAGG source for a short downsample window beyond raw retention, got: {}",
        response.sql
    );
}

#[test]
fn aggregate_metric_query_allows_one_year_timeframe() {
    let config = test_config();
    let query = "in:timeseries_metrics metric_type:snmp time:last_1y stats:avg(value) as avg_value";
    let ast = parser::parse(query).expect("query should parse");
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
        permitted_signals: None,
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
    let query = "in:timeseries_metrics time:last_1y";
    let ast = parser::parse(query).expect("query should parse");
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
        permitted_signals: None,
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
        cagg_column_for_entity(&Entity::TimeseriesMetrics, "avg", "value"),
        Some("avg_value")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::TimeseriesMetrics, "min", "value"),
        Some("min_value")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::TimeseriesMetrics, "sum", "value"),
        None
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::Flows, "sum", "bytes_total"),
        Some("bytes_total")
    );
}

#[test]
fn retired_sysmon_entities_fail_to_parse_with_a_replacement_query() {
    for (query, metric_type) in [
        ("in:cpu_metrics time:last_1h limit:5", "sysmon.cpu"),
        ("in:cpu time:last_1h limit:5", "sysmon.cpu"),
        ("in:memory_metrics time:last_1h limit:5", "sysmon.memory"),
        ("in:disk_metrics time:last_1h limit:5", "sysmon.disk"),
        ("in:process_metrics time:last_1h limit:5", "sysmon.process"),
        ("in:processes time:last_1h limit:5", "sysmon.process"),
    ] {
        let err = parser::parse(query).expect_err(query);
        let message = err.to_string();
        assert!(
            message.contains("retired entity"),
            "expected a retired-entity error for {query}, got: {message}"
        );
        assert!(
            message.contains(&format!("metric_type:\"{metric_type}\"")),
            "expected the error to name the {metric_type} replacement for {query}, got: {message}"
        );
    }
}
