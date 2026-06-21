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
        response.sql.contains("\"host\""),
        "device-scoped logs should match syslog host attributes, got: {}",
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
        sql.contains("order by 1 asc, 2 asc nulls first"),
        "expected stable rate downsample ordering by bucket+series, got: {}",
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
