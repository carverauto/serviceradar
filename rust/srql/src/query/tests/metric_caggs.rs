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
        168
    ));
    assert!(should_route_to_hourly_cagg(
        &Entity::TimeseriesMetrics,
        Some(&straddling),
        true,
        false,
        120
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
    let query = "in:timeseries_metrics metric_type:snmp time:last_1y stats:avg(value) as avg_value by metric_name";
    let ast = parser::parse(query).expect("query should parse");
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
        permitted_signals: None,
    };

    translate_request(&config, request.clone()).expect("stats query should translate");
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
fn legacy_sysmon_queries_translate_on_both_backends() {
    let config = test_config();
    for (aliases, metric_type, field, filter) in [
        (
            &["cpu", "cpu_metrics"][..],
            "sysmon.cpu",
            "usage_percent",
            "core_id:0 usage_percent:>70",
        ),
        (
            &["memory", "memory_metrics"][..],
            "sysmon.memory",
            "usage_percent",
            "used_bytes:>100",
        ),
        (
            &["disk", "disk_metrics"][..],
            "sysmon.disk",
            "usage_percent",
            "mount_point:/data",
        ),
        (
            &["process", "processes", "process_metrics"][..],
            "sysmon.process",
            "cpu_usage",
            "pid:123 name:worker",
        ),
    ] {
        for alias in aliases {
            for mode in [None, Some("starrocks"), Some("starrocks_raw")] {
                for shape in [
                    format!("{filter} sort:{field}:desc"),
                    if metric_type == "sysmon.cpu" {
                        format!("stats:avg({field})")
                    } else {
                        format!("stats:avg({field}) as average by device_id")
                    },
                    format!("stats:avg({field}) as average by device_id sort:average:desc"),
                    format!(
                        "{filter} bucket:5m agg:avg series:uid value_field:{field} sort:timestamp:desc"
                    ),
                ] {
                    let query = format!(
                        "in:{alias} device_id:host01.example.com time:last_1h {shape} limit:3"
                    );
                    let response = translate_request(
                        &config,
                        QueryRequest {
                            query: query.clone(),
                            limit: None,
                            cursor: None,
                            direction: QueryDirection::Next,
                            mode: mode.map(str::to_string),
                            permitted_signals: None,
                        },
                    )
                    .unwrap_or_else(|err| panic!("{query} ({mode:?}): {err}"));
                    assert!(
                        response.sql.contains("timeseries_metrics"),
                        "{}",
                        response.sql
                    );
                    assert!(
                        format!("{} {:?}", response.sql, response.params).contains(metric_type)
                    );
                    if !shape.contains("stats:") {
                        assert!(response.sql.contains(field), "{}", response.sql);
                    }
                    if shape.contains("bucket:") {
                        assert!(
                            response.sql.contains("windowed ORDER BY 1 ASC"),
                            "{}",
                            response.sql
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn legacy_sysmon_stats_rank_before_limiting_on_both_backends() {
    let config = test_config();
    for (entity, field) in [
        ("cpu", "usage_percent"),
        ("memory", "usage_percent"),
        ("disk", "usage_percent"),
        ("process", "cpu_usage"),
        ("process", "memory_usage"),
    ] {
        for mode in [None, Some("starrocks"), Some("starrocks_raw")] {
            for (sort, direction) in [("", "DESC"), ("sort:average:asc", "ASC")] {
                let response = translate_request(
                    &config,
                    QueryRequest {
                        query: format!(
                            "in:{entity} time:last_1h stats:avg({field}) as average by device_id {sort} limit:1"
                        ),
                        limit: None,
                        cursor: None,
                        direction: QueryDirection::Next,
                        mode: mode.map(str::to_string),
                        permitted_signals: None,
                    },
                )
                .expect("legacy ranked aggregate should compile");
                let column = if mode.is_none() {
                    "agg_value_0"
                } else {
                    "average"
                };
                assert!(
                    response
                        .sql
                        .contains(&format!("ORDER BY {column} {direction}")),
                    "{}",
                    response.sql
                );
            }
        }
    }
}

#[test]
fn legacy_sysmon_aggregates_keep_timeseries_retention_routing() {
    let config = test_config();
    for mode in [None, Some("starrocks"), Some("starrocks_raw")] {
        for shape in ["stats:avg(usage_percent) as average", "bucket:1h agg:avg"] {
            let response = translate_request(
                &config,
                QueryRequest {
                    query: format!("in:cpu time:last_30d {shape}"),
                    limit: None,
                    cursor: None,
                    direction: QueryDirection::Next,
                    mode: mode.map(str::to_string),
                    permitted_signals: None,
                },
            )
            .expect("legacy aggregate should compile");
            let hourly =
                mode.is_none() || (shape.starts_with("bucket:") && mode == Some("starrocks"));
            assert_eq!(
                response.sql.contains("timeseries_metrics_hourly"),
                hourly,
                "{}",
                response.sql
            );
        }
    }
}
