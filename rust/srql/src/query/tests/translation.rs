use super::*;

#[test]
fn translate_param_arity_matches_sql_placeholders() {
    let config = test_config();

    let cursor = encode_cursor(250, &config.cursor_secret).unwrap();

    let cases = [
            QueryRequest {
                query: "in:devices stats:count() as total".to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:services available:false time:last_24h stats:count() as failing"
                    .to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:gateways is_healthy:true status:ready sort:agent_count:desc".to_string(),
                limit: Some(10),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query:
                    "in:dashboards status:active srql_query:%cpu_metrics% sort:updated_at:desc"
                        .to_string(),
                limit: Some(25),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:devices time:last_7d sort:last_seen:desc is_available:true discovery_sources:(sweep,armis)".to_string(),
                limit: Some(20),
                cursor: Some(cursor.clone()),
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: r#"in:logs device_id:"sr:device-1" time:last_24h sort:timestamp:desc"#.to_string(),
                limit: Some(50),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:interfaces time:last_24h ip_addresses:(10.0.0.1,10.0.0.2) sort:timestamp:asc".to_string(),
                limit: Some(5),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:traces time:last_24h status_code:(1,2) kind:(1,2,3) sort:timestamp:desc".to_string(),
                limit: Some(25),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:device_graph device_id:dev-1 collector_owned_only:true include_topology:false".to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
        ];

    for request in cases {
        let response = match translate_request(&config, request.clone()) {
            Ok(response) => response,
            Err(err) => {
                panic!("translation failed for query '{}': {err:?}", request.query)
            }
        };
        let max_placeholder = super::max_dollar_placeholder(&response.sql);
        assert_eq!(
            max_placeholder,
            response.params.len(),
            "sql placeholders must match params length\nsql: {}\nparams: {:?}",
            response.sql,
            response.params
        );
    }
}

#[test]
fn translate_timestamp_sorted_severity_list_uses_bounded_topn_branches() {
    let config = test_config();
    let cursor = encode_cursor(40, &config.cursor_secret).unwrap();
    let request = QueryRequest {
        query: "in:logs severity_text:(fatal,critical,emergency,alert) time:last_24h sort:timestamp:desc limit:20".to_string(),
        limit: None,
        cursor: Some(cursor),
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    assert_eq!(
        response.sql.matches(" UNION ALL ").count(),
        3,
        "{}",
        response.sql
    );
    assert!(response.sql.starts_with("SELECT severity_topn.* FROM ("));
    assert!(!response.sql.contains(" = ANY("), "{}", response.sql);
    assert!(
        response.sql.contains(
            "ORDER BY COALESCE(severity_topn.observed_timestamp, severity_topn.\"timestamp\") DESC, severity_topn.id DESC"
        ),
        "{}",
        response.sql
    );
    assert_eq!(
        response.sql.matches("\"logs\".\"id\" DESC").count(),
        4,
        "every scalar branch must use the unique tie-breaker\n{}",
        response.sql
    );
    assert_eq!(
        response
            .params
            .iter()
            .filter(|param| matches!(param, BindParam::Int(60)))
            .count(),
        4,
        "each branch must retain the first two pages"
    );
    assert!(matches!(
        response.params.get(response.params.len() - 2),
        Some(BindParam::Int(20))
    ));
    assert!(matches!(response.params.last(), Some(BindParam::Int(40))));
    assert_eq!(
        super::max_dollar_placeholder(&response.sql),
        response.params.len(),
        "sql placeholders must be contiguous with params\nsql: {}\nparams: {:?}",
        response.sql,
        response.params
    );
}

#[test]
fn translate_includes_visualization_metadata() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics time:last_7d limit:10".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let viz = response.viz.expect("viz metadata should be present");

    assert!(
        viz.columns.iter().any(|col| {
            col.name == "timestamp" && matches!(col.col_type, viz::ColumnType::Timestamptz)
        }),
        "expected timestamp column meta, got: {:?}",
        viz.columns
    );

    assert!(
        viz.suggestions
            .iter()
            .any(|s| matches!(s.kind, viz::VizKind::Timeseries)),
        "expected timeseries suggestion, got: {:?}",
        viz.suggestions
    );
}

#[test]
fn translate_logs_device_id_resolves_inventory_aliases() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: r#"in:logs device_id:"sr:device-1" time:last_24h sort:timestamp:desc"#.to_string(),
        limit: Some(50),
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");

    assert!(
        response.sql.contains("platform.ocsf_devices"),
        "device-scoped logs should resolve inventory aliases, got: {}",
        response.sql
    );
    assert!(
        response
            .sql
            .contains("logs.source_ip IS NOT NULL AND logs.source_ip = d.ip"),
        "device-scoped logs should match inventory IPs on source_ip, got: {}",
        response.sql
    );
    assert!(
        !response.sql.contains("ILIKE"),
        "device-scoped logs must not scan attributes with ILIKE, got: {}",
        response.sql
    );
}

#[test]
fn translate_logs_without_time_gets_default_window() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:logs sort:timestamp:desc limit:25".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");

    assert!(
        response
            .sql
            .contains("COALESCE(observed_timestamp, timestamp) >= $1"),
        "logs list query should be lower-bounded by default, got: {}",
        response.sql
    );
    assert!(
        response
            .sql
            .contains("COALESCE(observed_timestamp, timestamp) <= $2"),
        "logs list query should be upper-bounded by default, got: {}",
        response.sql
    );
    assert_eq!(
        response.params.len(),
        4,
        "expected start/end plus limit/offset binds, got: {:?}",
        response.params
    );
}

#[test]
fn translate_logs_stats_without_time_gets_default_window() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: r#"in:logs stats:"count() as total""#.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");

    assert!(
        response
            .sql
            .contains("COALESCE(observed_timestamp, timestamp) >= $1")
            && response
                .sql
                .contains("COALESCE(observed_timestamp, timestamp) <= $2"),
        "logs stats query should be time-bounded by default, got: {}",
        response.sql
    );
    assert_eq!(
        response.params.len(),
        2,
        "expected start/end binds, got: {:?}",
        response.params
    );
}

#[test]
fn translate_downsample_emits_time_bucket_query() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics time:last_7d bucket:5m agg:avg series:metric_name limit:25"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");

    assert!(
        response.sql.to_lowercase().contains("to_timestamp(floor("),
        "expected floor-based time bucketing in SQL, got: {}",
        response.sql
    );
    assert!(
        response.sql.to_lowercase().contains("group by 1, 2"),
        "expected group by bucket+series, got: {}",
        response.sql
    );
    assert!(
        response
            .sql
            .to_lowercase()
            .contains("order by 1 asc, 2 asc nulls first"),
        "expected stable downsample ordering by bucket+series, got: {}",
        response.sql
    );

    let viz = response.viz.expect("viz metadata should be present");
    assert_eq!(viz.columns.len(), 3);
    assert!(
        viz.suggestions
            .iter()
            .any(|s| matches!(s.kind, viz::VizKind::Timeseries)),
        "expected timeseries suggestion, got: {:?}",
        viz.suggestions
    );

    assert!(
        response.params.len() >= 4,
        "expected time range + limit/offset params, got: {:?}",
        response.params
    );
}

#[test]
fn translate_timeseries_downsample_supports_sysmon_core_series_from_tags() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics metric_type:\"sysmon.cpu\" metric_name:\"cpu.usage_percent\" time:last_24h bucket:5m agg:max series:core_id limit:25".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");

    assert!(
        response
            .sql
            .contains("coalesce(tags->>'core_id', '') AS series"),
        "expected core_id series to be derived from metric tags, got: {}",
        response.sql
    );
}

#[test]
fn translate_timeseries_downsample_with_cagg_safe_filters_reads_hourly_cagg() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics metric_type:\"sysmon.cpu\" metric_name:\"cpu.usage_percent\" time:last_180d bucket:1h agg:avg series:uid limit:50000".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("from timeseries_metrics_hourly"),
        "expected normalized sysmon capacity source to read hourly CAGG, got: {}",
        response.sql
    );
    assert!(
        response.sql.contains("coalesce(device_id, '') AS series"),
        "expected uid alias to normalize to device_id series, got: {}",
        response.sql
    );
    assert!(
        sql.contains("metric_type = $3") && sql.contains("metric_name = $4"),
        "expected metric filters to remain bound on the CAGG route, got: {}",
        response.sql
    );
}

#[test]
fn translate_timeseries_downsample_with_non_cagg_series_stays_raw() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics metric_type:\"sysmon.cpu\" metric_name:\"cpu.usage_percent\" time:last_24h bucket:5m agg:avg series:core_id limit:25".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("from timeseries_metrics\n"),
        "core_id lives in tags and must stay on the raw table, got: {}",
        response.sql
    );
    assert!(
        response
            .sql
            .contains("coalesce(tags->>'core_id', '') AS series"),
        "expected core_id series to remain tag-derived, got: {}",
        response.sql
    );
}

#[test]
fn translate_downsample_allows_timeseries_series_key() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics metric_type:\"sysmon.cpu\" metric_name:\"cpu.usage_percent\" time:last_24h bucket:5m agg:max series:series_key limit:300".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");

    assert!(
        response.sql.contains("coalesce(series_key, '') AS series"),
        "expected series_key grouping, got: {}",
        response.sql
    );
    assert!(
        response.sql.contains("MAX(value) AS value"),
        "expected max aggregation, got: {}",
        response.sql
    );
}

#[test]
fn translate_timeseries_metric_interface_hourly_reads_interface_cagg() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metric_interface_hourly partition:edge-a time:last_180d sort:bucket:asc limit:5000".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");

    assert!(
        response
            .sql
            .contains("FROM timeseries_metrics_interface_hourly"),
        "expected interface hourly CAGG, got: {}",
        response.sql
    );
    assert!(
        response.sql.contains("ORDER BY bucket ASC"),
        "expected bucket ordering, got: {}",
        response.sql
    );
    assert!(
        response.sql.contains("partition"),
        "expected partition column/filter in interface hourly SQL, got: {}",
        response.sql
    );
    let sql = response.sql.to_lowercase();
    assert!(
        sql.contains("bucket >= time_bucket('1 hour', $1::timestamptz)")
            && sql.contains("bucket < time_bucket('1 hour', $2::timestamptz) + interval '1 hour'"),
        "expected interface CAGG bucket-overlap bounds for partial windows, got: {}",
        response.sql
    );

    let max_placeholder = super::max_dollar_placeholder(&response.sql);
    assert_eq!(
        max_placeholder,
        response.params.len(),
        "sql placeholders must match params length\nsql: {}\nparams: {:?}",
        response.sql,
        response.params
    );
}

#[test]
fn translate_timeseries_metric_interface_hourly_profile_uses_rate_cagg() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metric_interface_hourly metric_name:\"ifInOctets\" time:last_180d stats:profile_hour_of_week(value) timezone:\"Etc/UTC\" sort:series:asc,if_index:asc,dow:asc,hod:asc limit:50000".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");

    assert!(
        response
            .sql
            .contains("FROM timeseries_metrics_interface_hourly"),
        "expected interface hourly CAGG, got: {}",
        response.sql
    );
    assert!(
        response
            .sql
            .contains("avg_rate_per_second::float8 AS sample_value"),
        "expected profile to use interface rate samples, got: {}",
        response.sql
    );
    assert!(
        response.sql.contains("'if_index', l.if_index")
            && response
                .sql
                .contains("SELECT DISTINCT ON (series, if_index, metric_name)"),
        "expected per-ifIndex profile identity, got: {}",
        response.sql
    );
    assert!(
        response
            .sql
            .contains("ORDER BY l.series ASC, l.if_index ASC, l.dow ASC, l.hod ASC"),
        "expected interface profile ordering, got: {}",
        response.sql
    );

    let max_placeholder = super::max_dollar_placeholder(&response.sql);
    assert_eq!(
        max_placeholder,
        response.params.len(),
        "sql placeholders must match params length\nsql: {}\nparams: {:?}",
        response.sql,
        response.params
    );
}

#[test]
fn full_profiles_continue_past_the_generic_cursor_cap_in_translation() {
    let mut config = test_config();
    config.max_cursor_offset = 100;
    let cursor = encode_cursor(150, &config.cursor_secret).expect("cursor");
    let request = QueryRequest {
        query: "in:timeseries_metric_interface_hourly metric_name:\"ifInOctets\" time:last_180d stats:profile_hour_of_week_full(value) timezone:\"Etc/UTC\" sort:series:asc,if_index:asc,dow:asc,hod:asc limit:50".to_string(),
        limit: None,
        cursor: Some(cursor),
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("full-profile page above cap");
    let next = response
        .pagination
        .next_cursor
        .expect("next cursor remains available");
    assert_eq!(
        crate::pagination::decode_cursor(&next, &config.cursor_secret, i64::MAX).unwrap(),
        200
    );
}

#[test]
fn translate_downsample_respects_value_field() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:memory_metrics time:last_7d bucket:5m agg:avg value_field:used_bytes limit:10"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("avg(used_bytes)") || sql.contains("avg(avg_used_bytes)"),
        "expected downsample to use used_bytes or avg_used_bytes, got: {}",
        response.sql
    );
    assert!(
        sql.contains("bucket >= time_bucket('1 hour', $1::timestamptz)")
            && sql.contains("bucket < time_bucket('1 hour', $2::timestamptz) + interval '1 hour'"),
        "expected downsample CAGG bucket-overlap bounds for partial windows, got: {}",
        response.sql
    );
}

#[test]
fn translate_flows_downsample_emits_time_bucket_query() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total limit:25"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("from ocsf_network_activity"),
        "expected flows downsample to query ocsf_network_activity, got: {}",
        response.sql
    );
    assert!(
        sql.contains("to_timestamp(floor("),
        "expected floor-based time bucketing in SQL, got: {}",
        response.sql
    );
    assert!(
        sql.contains(
            "sum((bytes_total::double precision * greatest(coalesce(sampling_rate, 1), 1)::double precision))"
        ),
        "expected sampling-rate weighted sum(bytes_total), got: {}",
        response.sql
    );
    assert!(
        sql.contains("group by 1, 2"),
        "expected group by bucket+series, got: {}",
        response.sql
    );
    assert!(
        sql.contains("order by 1 asc, 2 asc nulls first"),
        "expected stable downsample ordering by bucket+series, got: {}",
        response.sql
    );

    let viz = response.viz.expect("viz metadata should be present");
    assert_eq!(viz.columns.len(), 3);
    assert!(
        viz.suggestions
            .iter()
            .any(|s| matches!(s.kind, viz::VizKind::Timeseries)),
        "expected timeseries suggestion, got: {:?}",
        viz.suggestions
    );
}

#[test]
fn translate_flows_app_filter_binds_value_and_correlates_override_rules() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:flows app:dusk time:last_24h sort:time:desc".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("app filter should translate");
    let sql = response.sql.to_lowercase();

    assert!(
        response
            .params
            .iter()
            .any(|param| matches!(param, BindParam::Text(value) if value == "dusk")),
        "expected the app filter value to be bound: {:?}",
        response.params
    );
    assert!(
        sql.contains("netflow_app_classification_rules")
            && sql.contains("r.partition = baseline.flow_partition")
            && sql.contains("r.protocol_num = baseline.flow_protocol_num"),
        "override rules must correlate to the outer flow row: {}",
        response.sql
    );
    assert!(
        !sql.contains("r.partition = partition") && !sql.contains("r.protocol_num = protocol_num"),
        "unqualified rule comparisons can resolve to the rule row itself: {}",
        response.sql
    );
}

#[test]
fn translate_flows_downsample_30d_reads_prescaled_cagg() {
    // §26.4: a long-window downsample (bucket:1h over 30d) routes to a pre-scaled flow CAGG
    // through the closed-vs-current UNION (fj #33). Pin that scaling is applied exactly once
    // on each side: the materialized (closed-bucket) CAGG side reads the pre-scaled
    // `bytes_total` column WITHOUT re-applying sampling_rate (no double-scaling — the CAGG
    // rebuild baked bytes * sampling_rate in at materialization), while the raw current-bucket
    // side DOES apply sampling_rate exactly once (raw rows are unscaled).
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:flows time:last_30d bucket:1h agg:sum value_field:bytes_total limit:25"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("from flow_traffic_1h"),
        "expected the long-window 1h bucket to route to the pre-scaled flow_traffic_1h CAGG: {sql}"
    );
    // Closed buckets read the pre-scaled column directly (NOT re-scaled).
    assert!(
        sql.contains("bytes_total::double precision as weighted_sum"),
        "CAGG (closed-bucket) side must read pre-scaled bytes_total without re-applying sampling_rate: {sql}"
    );
    // The current open bucket comes from raw and scales exactly once.
    assert!(
        sql.contains(
            "sum((bytes_total::double precision * greatest(coalesce(sampling_rate, 1), 1)::double precision)) as weighted_sum"
        ) && sql.contains("from ocsf_network_activity"),
        "raw current-bucket side must apply sampling_rate exactly once: {sql}"
    );
    assert!(
        sql.contains("sum(weighted_sum) as value"),
        "expected the outer sum over pre-scaled volume: {sql}"
    );
}

#[test]
fn translate_flows_downsample_can_filter_by_input_snmp() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query:
            "in:flows time:last_1h sampler_address:192.0.2.10 input_snmp:12 bucket:5m agg:sum value_field:bytes_total limit:25"
                .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("'{connection_info,input_snmp}'"),
        "expected input_snmp extraction in SQL, got: {}",
        response.sql
    );
    assert!(
        sql.contains("= $4"),
        "expected bound input_snmp equality after time and sampler params, got: {}",
        response.sql
    );
    assert!(
        sql.contains(
            "sum((bytes_total::double precision * greatest(coalesce(sampling_rate, 1), 1)::double precision))"
        ),
        "expected sampling-rate weighted sum(bytes_total), got: {}",
        response.sql
    );
    assert_eq!(response.params.len(), 6);
}

#[test]
fn translate_rate_downsample_orders_by_bucket_and_series() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:snmp time:last_1h bucket:5m agg:rate series:if_index limit:25".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("lag(value) over"),
        "expected rate downsample window query, got: {}",
        response.sql
    );
    assert!(
        sql.contains(
            "partition by gateway_id, coalesce(agent_id, ''), metric_type, metric_name, series_key"
        ),
        "expected rate LAG to partition by raw polling series, got: {}",
        response.sql
    );
    assert!(
        !sql.contains("partition by if_index::text"),
        "rate LAG must not partition by the display series alone, got: {}",
        response.sql
    );
    assert!(
        sql.contains("order by 1 asc, 2 asc nulls first"),
        "expected stable rate downsample ordering by bucket+series, got: {}",
        response.sql
    );
}

#[test]
fn translate_rate_downsample_is_counter_wrap_aware() {
    // A busy 1 Gbps link stores 32-bit Counter32 octets that wrap inside the poll
    // interval. The rate CTE must recover the real delta by adding the counter modulus
    // on a decrease (instead of dropping the wrapped sample as NULL), branching on the
    // per-sample counter_width column.
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:snmp metric_name:\"ifOutOctets\" time:last_1h bucket:5m agg:rate series:if_index limit:25"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("counter_width = 32"),
        "expected explicit 32-bit wrap branch, got: {}",
        response.sql
    );
    assert!(
        sql.contains("counter_width = 64"),
        "expected explicit 64-bit wrap branch, got: {}",
        response.sql
    );
    assert!(
        sql.contains("4294967296"),
        "expected 2^32 modulus added on wrap, got: {}",
        response.sql
    );
    assert!(
        sql.contains("18446744073709551616"),
        "expected 2^64 modulus added on HC wrap, got: {}",
        response.sql
    );
    assert!(
        sql.contains("metadata->>'max_counter_rate_per_second'"),
        "expected producer-supplied plausibility ceiling extraction, got: {}",
        response.sql
    );
    assert!(
        sql.contains("max_rate_per_second is not null"),
        "expected 64-bit wrap salvage to require a plausibility ceiling, got: {}",
        response.sql
    );
    assert!(
        sql.contains("coalesce(max_rate_per_second, 4294967296)"),
        "expected 32-bit wrap salvage to be plausibility-bounded, got: {}",
        response.sql
    );
    // The unknown-width legacy branch only assumes a 32-bit wrap when the previous value
    // still fit in 32 bits; a larger prev value is treated as a genuine reset.
    assert!(
        sql.contains("prev_value < 4294967296"),
        "expected unknown-width 32-bit heuristic guard, got: {}",
        response.sql
    );
    // The old unconditional drop-on-decrease must be gone for counter_width tables.
    assert!(
        !sql.contains("when value < prev_value then null"),
        "expected wrap-aware CTE to replace the drop-on-decrease rule, got: {}",
        response.sql
    );
}

#[test]
fn translate_graph_cypher_rejects_mutations() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:graph_cypher cypher:\"CREATE (n:Device {id:'x'}) RETURN 1 as result\""
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let err = translate_request(&config, request).expect_err("should reject write cypher");
    assert!(
        err.to_string().to_lowercase().contains("read-only"),
        "expected read-only error, got: {err}"
    );
}

#[test]
fn translate_graph_cypher_rejects_mutations_without_keyword_spacing() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: r#"in:graph_cypher cypher:"MATCH (n) CREATE(m:Device {id:'x'}) RETURN n""#
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let err = translate_request(&config, request).expect_err("should reject write cypher");
    assert!(
        err.to_string().to_lowercase().contains("read-only"),
        "expected read-only error, got: {err}"
    );
}

#[test]
fn translate_graph_cypher_ignores_keywords_inside_literals_and_comments() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: r#"in:graph_cypher cypher:"MATCH (n) WHERE n.note = 'delete; merge' // set ignored
RETURN {id: n.id, label: 'create'} AS result" limit:10"#
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    assert!(
        response.sql.contains("ag_catalog.cypher"),
        "expected graph_cypher SQL, got: {}",
        response.sql
    );
}

#[test]
fn translate_graph_cypher_still_rejects_mutations_after_comments() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query:
            r#"in:graph_cypher cypher:"MATCH (n) /* delete ignored */ SET n.name = 'x' RETURN n""#
                .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let err = translate_request(&config, request).expect_err("should reject write cypher");
    assert!(
        err.to_string().to_lowercase().contains("read-only"),
        "expected read-only error, got: {err}"
    );
}

#[test]
fn translate_graph_cypher_wraps_rows_as_topology_payload() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:graph_cypher cypher:\"MATCH (n) RETURN n\" limit:10".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("jsonb_build_object('nodes'"),
        "expected topology wrapper in SQL, got: {}",
        response.sql
    );
    assert!(
        sql.contains("jsonb_build_array"),
        "expected jsonb_build_array in SQL, got: {}",
        response.sql
    );
    assert_eq!(
        response.params.len(),
        2,
        "expected limit + offset binds, got: {:?}",
        response.params
    );
}

#[test]
fn translate_device_filtered_hourly_downsample_routes_to_timeseries_cagg() {
    // Regression: device-detail metric charts filter by metric_type/metric_name and group by
    // device_id over multi-hour windows. These only touch CAGG group keys, so an hourly bucket
    // must route to `timeseries_metrics_hourly` instead of re-aggregating the raw hypertable.
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics metric_type:\"snmp\" metric_name:\"ifHCInOctets\" time:last_24h bucket:1h agg:avg series:device_id limit:1000".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("from timeseries_metrics_hourly"),
        "expected device-filtered hourly downsample to read the CAGG, got: {}",
        response.sql
    );
    assert!(
        sql.contains("avg(avg_value) as value"),
        "expected mean-of-means over the CAGG avg column, got: {}",
        response.sql
    );
    assert!(
        sql.contains("bucket >= time_bucket('1 hour'"),
        "expected CAGG bucket bounds, got: {}",
        response.sql
    );
}

#[test]
fn translate_agent_filtered_hourly_downsample_stays_on_raw_hypertable() {
    // agent_id is NOT a CAGG group key (it was collapsed during materialization), so an
    // agent-filtered query must stay on the raw hypertable to remain correct.
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics metric_type:\"snmp\" metric_name:\"ifHCInOctets\" agent_id:\"default-agent\" time:last_24h bucket:1h agg:avg series:device_id limit:1000".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        !sql.contains("timeseries_metrics_hourly"),
        "agent_id-filtered query must not route to the CAGG, got: {}",
        response.sql
    );
    assert!(
        sql.contains("avg(value) as value"),
        "expected raw-column aggregation, got: {}",
        response.sql
    );
}

#[test]
fn translate_subhour_device_filtered_downsample_stays_on_raw_hypertable() {
    // A 5-minute bucket cannot be served by the hourly CAGG even with CAGG-safe filters.
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics metric_type:\"snmp\" metric_name:\"ifHCInOctets\" time:last_24h bucket:5m agg:avg series:device_id limit:1000".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    assert!(
        !response
            .sql
            .to_lowercase()
            .contains("timeseries_metrics_hourly"),
        "sub-hour bucket must not route to the hourly CAGG, got: {}",
        response.sql
    );
}

#[test]
fn translate_hourly_max_downsample_reads_cagg_max_value_column() {
    // MIN/MAX must read the matching pre-aggregated column so max-of-maxes / min-of-mins stays
    // exact when serving from the CAGG.
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics metric_type:\"snmp\" metric_name:\"ifHCInOctets\" device_id:\"abc\" time:last_24h bucket:1h agg:max limit:1000".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();
    assert!(
        sql.contains("from timeseries_metrics_hourly"),
        "expected CAGG source for device-filtered hourly max, got: {}",
        response.sql
    );
    assert!(
        sql.contains("max(max_value) as value"),
        "expected max-of-maxes over the CAGG max column, got: {}",
        response.sql
    );
}

// A `bucket:` chart always renders oldest-first, but `sort:time:desc limit:N` is asking
// which END of the window survives the LIMIT. The ordering used to be hardcoded ascending
// and `plan.order` was discarded, so a 30-day chart at `bucket:5m limit:100` silently
// returned the OLDEST 100 buckets and stopped two weeks short of now.
#[test]
fn translate_downsample_sort_desc_truncates_from_the_newest_bucket() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query:
            "in:flows time:last_30d bucket:5m agg:sum value_field:bytes_total series:app dst_ip:34.98.126.170 sort:time:desc limit:100"
                .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("order by 1 desc, 2 asc nulls first"),
        "sort:time:desc must truncate from the newest bucket: {sql}"
    );
    assert!(
        sql.trim_end()
            .ends_with("order by 1 asc, 2 asc nulls first"),
        "rows must still come back oldest-first for charting: {sql}"
    );
}

// No `sort:` means no opinion about which end to keep, so the pre-existing ascending
// truncation is preserved -- this change only reacts to an explicit descending sort.
#[test]
fn translate_downsample_without_sort_keeps_ascending_truncation() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:flows time:last_30d bucket:5m agg:sum value_field:bytes_total series:app dst_ip:34.98.126.170 limit:100"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        !sql.contains("order by 1 desc"),
        "an unsorted downsample must not flip the truncation direction: {sql}"
    );
    assert!(
        !sql.contains(") windowed"),
        "an unsorted downsample must not grow the truncation wrapper: {sql}"
    );
    assert!(
        sql.contains("order by 1 asc, 2 asc nulls first"),
        "expected the plain ascending tail: {sql}"
    );
}

// The flow CAGG union path and the rate path build their SQL separately from the standard
// aggregation path, so each needs its own proof that `sort:` reaches the tail.
#[test]
fn translate_downsample_sort_desc_applies_on_cagg_and_rate_paths() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());

    for query in [
        // Routes to flow_traffic_1h via build_flow_cagg_union_sql (no filters, no series).
        "in:flows time:last_30d bucket:1h agg:sum value_field:bytes_total sort:time:desc limit:25",
        // Routes to the rate CTE path.
        "in:snmp time:last_1h bucket:5m agg:rate series:if_index sort:time:desc limit:25",
    ] {
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = translate_request(&config, request).expect("translation should succeed");
        let sql = response.sql.to_lowercase();

        assert!(
            sql.contains("order by 1 desc, 2 asc nulls first"),
            "{query} must truncate from the newest bucket: {sql}"
        );
        assert!(
            sql.trim_end()
                .ends_with("order by 1 asc, 2 asc nulls first"),
            "{query} must still return rows oldest-first: {sql}"
        );
    }
}

// `ip:` / `cidr:` match EITHER flow endpoint, mirroring the bare `near:` form
// (`NearSide::Either`). Without them "all traffic for host X" needs two queries,
// because SRQL has no cross-field OR and every other IP filter is one-sided.
#[test]
fn translate_flows_bidirectional_ip_matches_either_endpoint() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:flows time:last_30d ip:34.98.126.170 sort:time:desc limit:100".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("src_endpoint_ip") && sql.contains("dst_endpoint_ip") && sql.contains(" or "),
        "ip: must OR both endpoints: {sql}"
    );
    // The bind must be collected once per side or the LIMIT/OFFSET binds shift.
    assert_eq!(
        response
            .params
            .iter()
            .filter(|param| matches!(param, BindParam::Text(v) if v == "34.98.126.170"))
            .count(),
        2,
        "expected one bind per endpoint: {:?}",
        response.params
    );
    assert_eq!(
        super::max_dollar_placeholder(&response.sql),
        response.params.len(),
        "sql placeholders must stay contiguous with params\nsql: {}\nparams: {:?}",
        response.sql,
        response.params
    );
}

// "Neither endpoint is X" is the AND of the two per-side negatives (De Morgan).
// ORing them would match every row whose two endpoints merely differ.
#[test]
fn translate_flows_negated_bidirectional_ip_requires_both_sides_to_miss() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:flows time:last_1h !ip:10.0.0.1 limit:10".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains(" and "),
        "negated ip: must AND the per-side negatives, not OR them: {sql}"
    );
    assert!(
        sql.contains("is null"),
        "each side must stay NULL-safe: {sql}"
    );
}

#[test]
fn translate_flows_bidirectional_cidr_matches_either_endpoint() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());

    // Raw path: CIDR literals are inlined (validated by normalize_cidr_literal), no binds.
    let request = QueryRequest {
        query: "in:flows time:last_1h cidr:203.0.113.0/24 limit:10".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };
    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();
    assert!(
        sql.contains("try_inet(nullif(src_endpoint_ip, '')) <<= '203.0.113.0/24'::cidr")
            && sql.contains("try_inet(nullif(dst_endpoint_ip, '')) <<= '203.0.113.0/24'::cidr"),
        "cidr: must test containment on both endpoints: {sql}"
    );

    // Stats path binds the literal instead, once per side.
    let request = QueryRequest {
        query: "in:flows time:last_24h cidr:203.0.113.0/24 stats:sum(bytes_total) as bytes by app"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };
    let response = translate_request(&config, request).expect("translation should succeed");
    assert_eq!(
        response
            .params
            .iter()
            .filter(|param| matches!(param, BindParam::Text(v) if v == "203.0.113.0/24"))
            .count(),
        2,
        "stats cidr: needs one bind per endpoint: {:?}",
        response.params
    );
    assert_eq!(
        super::max_dollar_placeholder(&response.sql),
        response.params.len(),
        "sql placeholders must stay contiguous with params\nsql: {}\nparams: {:?}",
        response.sql,
        response.params
    );
}

// `ip` is already on the parser's implicit-LIKE allowlist, so the wildcard form has to
// work on the chart path too -- that path builds its filters independently.
#[test]
fn translate_flows_bidirectional_ip_works_on_stats_and_downsample_paths() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());

    for query in [
        "in:flows time:last_24h ip:34.98.126.170 stats:sum(bytes_total) as bytes by app",
        "in:flows time:last_30d bucket:1h agg:sum value_field:bytes_total ip:34.98.126.170 limit:1000",
        "in:flows time:last_30d bucket:1h agg:sum value_field:bytes_total ip:%34.98.126.% limit:1000",
    ] {
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = translate_request(&config, request).expect("translation should succeed");
        let sql = response.sql.to_lowercase();

        assert!(
            sql.contains("src_endpoint_ip") && sql.contains("dst_endpoint_ip"),
            "{query} must reference both endpoints: {sql}"
        );
        assert_eq!(
            super::max_dollar_placeholder(&response.sql),
            response.params.len(),
            "{query}: sql placeholders must stay contiguous with params\nsql: {}\nparams: {:?}",
            response.sql,
            response.params
        );
    }
}

// Chart queries (`bucket:` / downsample) previously rejected `cidr:` even though
// the row and stats paths already accepted it (and bare `cidr:` is in the catalog).
#[test]
fn translate_flows_cidr_works_on_stats_and_downsample_paths() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());

    for query in [
        "in:flows time:last_1h cidr:10.0.0.0/8 stats:sum(bytes_total) as bytes by app",
        "in:flows time:last_1h bucket:5m agg:avg value_field:bytes_total series:app cidr:10.0.0.0/8 sort:time:desc limit:100",
        "in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total src_cidr:10.0.0.0/8 limit:100",
        "in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total dst_cidr:192.168.0.0/16 limit:100",
    ] {
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = translate_request(&config, request)
            .unwrap_or_else(|err| panic!("translation should succeed for {query}: {err:?}"));
        let sql = response.sql.to_lowercase();

        assert!(
            sql.contains("<<= ") || sql.contains("<<="),
            "{query} must emit a CIDR containment clause: {sql}"
        );
        assert!(
            sql.contains("src_endpoint_ip") || sql.contains("dst_endpoint_ip"),
            "{query} must reference an endpoint IP column: {sql}"
        );
        assert_eq!(
            super::max_dollar_placeholder(&response.sql),
            response.params.len(),
            "{query}: sql placeholders must stay contiguous with params\nsql: {}\nparams: {:?}",
            response.sql,
            response.params
        );
    }
}
