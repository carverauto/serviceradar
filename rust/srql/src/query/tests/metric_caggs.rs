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
    assert!(parser::parse("in:process time:last_1h").is_err());
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
            &["processes", "process_metrics"][..],
            "sysmon.process",
            "cpu_usage",
            "pid:123 name:worker",
        ),
    ] {
        for alias in aliases {
            for mode in [None, Some("starrocks"), Some("starrocks_raw")] {
                for shape in [
                    format!("{filter} sort:host_id:asc,{field}:desc"),
                    if metric_type == "sysmon.cpu" {
                        format!("stats:avg({field})")
                    } else {
                        format!("stats:avg({field}) as average by device_id")
                    },
                    format!("stats:avg({field}) as average by device_id sort:average:desc"),
                    format!(
                        "{filter} bucket:5m agg:avg series:host_id value_field:{field} sort:timestamp:desc"
                    ),
                ] {
                    let query = format!(
                        "in:{alias} host_id:host01.example.com time:last_1h {shape} limit:3"
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
                    let host = if mode.is_none() {
                        "tags ->> 'host_id'"
                    } else {
                        "get_json_string(tags, '$.host_id')"
                    };
                    assert!(response.sql.contains(host), "{}", response.sql);
                    assert!(
                        format!("{} {:?}", response.sql, response.params)
                            .contains("host01.example.com")
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
        ("processes", "cpu_usage"),
        ("processes", "memory_usage"),
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
fn metric_charts_use_rollups_only_for_integral_hour_buckets() {
    let config = test_config();
    for entity in ["cpu", "memory", "disk", "processes", "timeseries_metrics"] {
        for (bucket, covered) in [("5m", false), ("90m", false), ("1h", true), ("2h", true)] {
            for mode in [None, Some("starrocks"), Some("starrocks_raw")] {
                let response = translate_request(
                    &config,
                    QueryRequest {
                        query: format!("in:{entity} device_id:host01.example.com time:last_30d bucket:{bucket} agg:avg series:device_id"),
                        limit: None,
                        cursor: None,
                        direction: QueryDirection::Next,
                        mode: mode.map(str::to_string),
                        permitted_signals: None,
                    },
                ).expect("metric chart should translate");
                assert_eq!(
                    response.sql.contains("_hourly"),
                    covered && mode != Some("starrocks_raw"),
                    "{}",
                    response.sql
                );
            }
        }
    }
}

#[test]
fn legacy_sysmon_fresh_and_raw_translations_preserve_effective_window() {
    let config = test_config();
    for (entity, value) in [
        ("cpu", "usage_percent"),
        ("memory", "usage_percent"),
        ("disk", "usage_percent"),
        ("processes", "cpu_usage"),
    ] {
        for shape in [
            format!("stats:avg({value}) as average by device_id"),
            "bucket:1h agg:avg series:device_id".into(),
            "bucket:2h agg:count series:device_id".into(),
        ] {
            for (end, upper) in [("06:15:00", "07:00:00"), ("07:00:00", "08:00:00")] {
                for mode in ["starrocks", "starrocks_raw"] {
                    let response = translate_request(
                        &config,
                        QueryRequest {
                            query: format!(
                                "in:{entity} time:[2026-09-11T00:15:00Z,2026-09-11T{end}Z] {shape}"
                            ),
                            limit: None,
                            cursor: None,
                            direction: QueryDirection::Next,
                            mode: Some(mode.into()),
                            permitted_signals: None,
                        },
                    )
                    .expect("aggregate should translate for either freshness state");
                    assert_eq!(
                        response.sql.contains("_hourly"),
                        mode == "starrocks",
                        "{}",
                        response.sql
                    );
                    assert!(
                        response.sql.contains(">= '2026-09-11 00:00:00.000000'"),
                        "{}",
                        response.sql
                    );
                    assert!(
                        response
                            .sql
                            .contains(&format!("< '2026-09-11 {upper}.000000'")),
                        "{}",
                        response.sql
                    );
                }
            }
        }
    }
}

#[test]
fn legacy_sysmon_aggregates_keep_timeseries_retention_routing() {
    let config = test_config();
    let old_start = chrono::Utc::now() - ChronoDuration::days(10);
    let old_end = old_start + ChronoDuration::hours(3);
    let old_window = format!(
        "time:[{},{}]",
        old_start.format("%Y-%m-%dT%H:%M:%SZ"),
        old_end.format("%Y-%m-%dT%H:%M:%SZ")
    );
    for mode in [None, Some("starrocks"), Some("starrocks_raw")] {
        for (window, eligible) in [
            ("time:last_30d", true),
            (old_window.as_str(), true),
            ("time:last_1h", false),
        ] {
            for (shape, table) in [
                (
                    "cpu stats:avg(usage_percent) as average",
                    "timeseries_metrics_hourly",
                ),
                (
                    "memory stats:avg(usage_percent) as average by device_id",
                    "timeseries_metrics_hourly",
                ),
                (
                    "processes stats:avg(memory_usage) as average by device_id",
                    "timeseries_metrics_hourly",
                ),
                (
                    "disk mount_point:/data stats:avg(usage_percent) as average by device_id",
                    "timeseries_metrics_disk_hourly",
                ),
                (
                    "disk bucket:5m agg:avg series:mount_point",
                    "timeseries_metrics",
                ),
                (
                    "disk bucket:1h agg:avg series:mount_point",
                    "timeseries_metrics_disk_hourly",
                ),
                ("cpu bucket:5m agg:avg series:uid", "timeseries_metrics"),
                ("cpu bucket:1h agg:min", "timeseries_metrics_hourly"),
                ("cpu bucket:1h agg:max", "timeseries_metrics_hourly"),
                ("cpu bucket:1h agg:sum", "timeseries_metrics_hourly"),
                ("cpu bucket:1h agg:count", "timeseries_metrics_hourly"),
                (
                    "cpu bucket:1h agg:avg value_field:frequency_hz",
                    "timeseries_metrics_hourly",
                ),
                (
                    "cpu host_id:host01.example.com stats:avg(usage_percent) as average",
                    "timeseries_metrics",
                ),
                (
                    "memory stats:avg(used_bytes) as average by device_id",
                    "timeseries_metrics",
                ),
                (
                    "disk bucket:5m agg:avg value_field:available_bytes",
                    "timeseries_metrics",
                ),
                (
                    "processes name:worker stats:avg(cpu_usage) as average by device_id",
                    "timeseries_metrics",
                ),
                ("cpu bucket:1h agg:last", "timeseries_metrics"),
            ] {
                let response = translate_request(
                    &config,
                    QueryRequest {
                        query: format!("in:{shape} {window}"),
                        limit: None,
                        cursor: None,
                        direction: QueryDirection::Next,
                        mode: mode.map(str::to_string),
                        permitted_signals: None,
                    },
                )
                .expect("legacy aggregate should compile");
                let hourly = eligible
                    && mode != Some("starrocks_raw")
                    && table != "timeseries_metrics"
                    && (table != "timeseries_metrics_disk_hourly" || mode.is_none());
                assert_eq!(response.sql.contains("_hourly"), hourly, "{}", response.sql);
                if hourly {
                    assert!(response.sql.contains(table), "{}", response.sql);
                    if shape.contains("agg:avg") || shape.contains("stats:") {
                        assert!(
                            response.sql.contains("/ NULLIF(SUM(sample_count), 0)"),
                            "{}",
                            response.sql
                        );
                    }
                }
            }
        }
    }
}
