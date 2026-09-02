mod support;

use serial_test::serial;
use support::harness::SrqlTestHarness;
use support::{read_json, with_srql_harness};

use srql::query::{QueryDirection, QueryRequest};

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn srql_api_queries() {
    with_srql_harness(|harness| async move {
        check_mtr_traces_query_contract(&harness).await;
        check_devices_inventory_query_matches_fixture(&harness).await;
        check_invalid_field_returns_400(&harness).await;
        check_missing_api_key_returns_401(&harness).await;
        check_device_graph_query_returns_neighborhood(&harness).await;
        check_device_graph_query_rejects_invalid_device_id(&harness).await;
        check_timeseries_metrics_query_returns_rows(&harness).await;
        check_timeseries_other_rollup_returns_tail_row(&harness).await;
        check_timeseries_metrics_profile_hour_of_week(&harness).await;
        check_snmp_metrics_alias_filters_metric_type(&harness).await;
        check_rperf_metrics_queries_still_work(&harness).await;
        check_virtualization_inventory_queries(&harness).await;
        check_logs_severity_topn_paginates_by_effective_timestamp(&harness).await;
    })
    .await;
}

async fn query_ok(harness: &SrqlTestHarness, query: &str) -> serde_json::Value {
    let response = harness
        .query(QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        })
        .await;
    let (status, body) = read_json(response).await;
    assert_eq!(
        status,
        http::StatusCode::OK,
        "unexpected error for query '{query}': {body}"
    );
    body
}

async fn check_mtr_traces_query_contract(harness: &SrqlTestHarness) {
    // Exact public reproduction from #4206: a catalog-advertised entity must execute,
    // not merely parse or translate.
    let issue_body = query_ok(harness, "in:mtr_traces time:last_1h sort:time:desc limit:1").await;
    assert_eq!(
        issue_body["results"][0]["id"],
        "00000000-0000-4000-8000-000000000010"
    );

    // Exercise every catalog-advertised filter together, including the boolean, while
    // proving the otherwise-identical row outside the requested time window is excluded.
    let filtered_body = query_ok(
        harness,
        r#"in:mtr_traces target:"edge.example" target_ip:"203.0.113.10" agent_id:"agent-mtr-a" protocol:icmp check_name:"edge-check" device_id:"device-mtr-a" target_reached:false error:"destination timeout" time:last_1h sort:time:desc limit:1"#,
    )
    .await;
    let filtered_rows = filtered_body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("results must be an array: {filtered_body}"));
    assert_eq!(filtered_rows.len(), 1, "{filtered_body}");
    let row = filtered_rows[0]
        .as_object()
        .unwrap_or_else(|| panic!("MTR result must be an object: {filtered_body}"));
    let expected_columns = [
        "id",
        "time",
        "agent_id",
        "gateway_id",
        "check_id",
        "check_name",
        "device_id",
        "target",
        "target_ip",
        "target_reached",
        "total_hops",
        "protocol",
        "ip_version",
        "packet_size",
        "partition",
        "error",
        "created_at",
    ];
    assert_eq!(
        row.len(),
        expected_columns.len(),
        "MTR rows must serialize the authoritative table shape: {filtered_body}"
    );
    for column in expected_columns {
        assert!(
            row.contains_key(column),
            "MTR result is missing '{column}': {filtered_body}"
        );
    }
    assert_eq!(row["id"], "00000000-0000-4000-8000-000000000020");
    assert!(row["time"].is_string(), "{filtered_body}");
    assert_eq!(row["agent_id"], "agent-mtr-a");
    assert_eq!(row["gateway_id"], "gateway-mtr-a");
    assert_eq!(row["check_id"], "check-mtr-a");
    assert_eq!(row["check_name"], "edge-check");
    assert_eq!(row["device_id"], "device-mtr-a");
    assert_eq!(row["target"], "edge.example");
    assert_eq!(row["target_ip"], "203.0.113.10");
    assert_eq!(row["target_reached"], false);
    assert_eq!(row["total_hops"], 12);
    assert_eq!(row["protocol"], "icmp");
    assert_eq!(row["ip_version"], 4);
    assert_eq!(row["packet_size"], 64);
    assert_eq!(row["partition"], "partition-mtr-a");
    assert_eq!(row["error"], "destination timeout");
    assert!(row["created_at"].is_string(), "{filtered_body}");

    // Each advertised filter must independently narrow the fixture. A combined-only
    // assertion could still pass if one predicate were accidentally omitted.
    let filter_cases: [(&str, &[&str]); 8] = [
        (
            "target:%edge.example%",
            &["00000000-0000-4000-8000-000000000020"],
        ),
        (
            "target_ip:%113.10%",
            &["00000000-0000-4000-8000-000000000020"],
        ),
        (
            "agent_id:%mtr-a%",
            &["00000000-0000-4000-8000-000000000020"],
        ),
        (
            "protocol:icmp",
            &[
                "00000000-0000-4000-8000-000000000010",
                "00000000-0000-4000-8000-000000000020",
            ],
        ),
        (
            "check_name:%edge%",
            &["00000000-0000-4000-8000-000000000020"],
        ),
        (
            "device_id:%mtr-a%",
            &["00000000-0000-4000-8000-000000000020"],
        ),
        (
            "target_reached:false",
            &["00000000-0000-4000-8000-000000000020"],
        ),
        ("error:%timeout%", &["00000000-0000-4000-8000-000000000020"]),
    ];

    for (filter, expected_ids) in filter_cases {
        let body = query_ok(
            harness,
            &format!("in:mtr_traces {filter} time:last_1h sort:time:desc limit:20"),
        )
        .await;
        let ids: Vec<_> = body["results"]
            .as_array()
            .unwrap_or_else(|| panic!("results must be an array for {filter}: {body}"))
            .iter()
            .map(|result| {
                result["id"]
                    .as_str()
                    .unwrap_or_else(|| panic!("MTR row must include an id: {body}"))
            })
            .collect();
        assert_eq!(
            ids, expected_ids,
            "filter {filter} was not enforced: {body}"
        );
    }

    // Absolute time windows are half-open: include the row exactly at the lower bound,
    // include the interior row, and exclude the row exactly at the upper bound.
    let bounded_body = query_ok(
        harness,
        r#"in:mtr_traces target:"absolute.example" time:[2026-06-01T00:00:00Z,2026-06-01T01:00:00Z] sort:time:asc limit:10"#,
    )
    .await;
    let bounded_ids: Vec<_> = bounded_body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("results must be an array: {bounded_body}"))
        .iter()
        .map(|result| result["id"].as_str().expect("MTR row must include an id"))
        .collect();
    assert_eq!(
        bounded_ids,
        [
            "00000000-0000-4000-8000-000000000100",
            "00000000-0000-4000-8000-000000000101",
        ],
        "upper-bound row must be excluded: {bounded_body}"
    );

    // The primary-key UUID breaks timestamp ties across real cursor pages, keeping
    // pagination stable without skipping or repeating equal-time rows.
    let tied_query = r#"in:mtr_traces target:"tie.example" time:last_1h sort:time:desc limit:1"#;
    let expected_tied_ids = [
        "00000000-0000-4000-8000-000000000002",
        "00000000-0000-4000-8000-000000000001",
    ];
    let mut cursor = None;
    let mut tied_rows = Vec::new();

    for expected_id in expected_tied_ids {
        let response = harness
            .query(QueryRequest {
                query: tied_query.to_string(),
                limit: None,
                cursor,
                direction: QueryDirection::Next,
                mode: None,
            })
            .await;
        let (status, body) = read_json(response).await;
        assert_eq!(status, http::StatusCode::OK, "{body}");
        let rows = body["results"]
            .as_array()
            .unwrap_or_else(|| panic!("results must be an array: {body}"));
        assert_eq!(
            rows.len(),
            1,
            "each cursor page must contain one row: {body}"
        );
        assert_eq!(rows[0]["id"], expected_id, "timestamp tie order: {body}");
        tied_rows.push(rows[0].clone());
        cursor = body["pagination"]["next_cursor"]
            .as_str()
            .map(str::to_string);
        assert!(
            cursor.is_some(),
            "a full page must provide a cursor: {body}"
        );
    }

    let exhausted_response = harness
        .query(QueryRequest {
            query: tied_query.to_string(),
            limit: None,
            cursor,
            direction: QueryDirection::Next,
            mode: None,
        })
        .await;
    let (exhausted_status, exhausted_body) = read_json(exhausted_response).await;
    assert_eq!(exhausted_status, http::StatusCode::OK, "{exhausted_body}");
    assert_eq!(exhausted_body["results"], serde_json::json!([]));
    assert!(exhausted_body["pagination"]["next_cursor"].is_null());

    let mut seen_tied_ids: Vec<_> = tied_rows
        .iter()
        .map(|row| row["id"].as_str().expect("MTR row must include an id"))
        .collect();
    seen_tied_ids.sort_unstable();
    seen_tied_ids.dedup();
    assert_eq!(seen_tied_ids.len(), expected_tied_ids.len());

    let null_row = tied_rows
        .iter()
        .find(|result| result["id"] == "00000000-0000-4000-8000-000000000001")
        .expect("fixture must return its nullable row");
    for column in [
        "gateway_id",
        "check_id",
        "check_name",
        "device_id",
        "packet_size",
        "partition",
        "error",
    ] {
        assert!(
            null_row[column].is_null(),
            "optional '{column}' must serialize as null: {null_row}"
        );
    }
}

async fn check_logs_severity_topn_paginates_by_effective_timestamp(harness: &SrqlTestHarness) {
    let query = "in:logs source:\"srql-topn-tie\" severity_text:(FATAL,CRITICAL) time:last_1h sort:timestamp:desc limit:1";
    let expected_ids = [
        "00000000-0000-0000-0000-000000000004",
        "00000000-0000-0000-0000-000000000003",
        "00000000-0000-0000-0000-000000000002",
        "00000000-0000-0000-0000-000000000001",
    ];
    let mut cursor = None;
    let mut seen_ids = Vec::new();

    for expected_id in expected_ids {
        let response = harness
            .query(QueryRequest {
                query: query.to_string(),
                limit: None,
                cursor,
                direction: QueryDirection::Next,
                mode: None,
            })
            .await;
        let (status, body) = read_json(response).await;

        assert_eq!(status, http::StatusCode::OK, "{body}");
        let rows = body["results"]
            .as_array()
            .unwrap_or_else(|| panic!("results must be an array: {body}"));
        assert_eq!(rows.len(), 1, "each page must contain one tied row: {body}");
        let id = rows[0]["id"]
            .as_str()
            .unwrap_or_else(|| panic!("row must include its id: {body}"));
        assert_eq!(id, expected_id, "timestamp ties must be UUID-desc: {body}");
        seen_ids.push(id.to_string());
        cursor = body["pagination"]["next_cursor"]
            .as_str()
            .map(str::to_string);
        assert!(
            cursor.is_some(),
            "full page must provide next cursor: {body}"
        );
    }

    assert_eq!(
        seen_ids, expected_ids,
        "no tied row may be skipped or repeated"
    );
    let mut unique_ids = seen_ids.clone();
    unique_ids.sort();
    unique_ids.dedup();
    assert_eq!(unique_ids.len(), expected_ids.len());

    let exhausted_response = harness
        .query(QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor,
            direction: QueryDirection::Next,
            mode: None,
        })
        .await;
    let (exhausted_status, exhausted_body) = read_json(exhausted_response).await;
    assert_eq!(exhausted_status, http::StatusCode::OK, "{exhausted_body}");
    assert_eq!(exhausted_body["results"], serde_json::json!([]));
    assert!(exhausted_body["pagination"]["next_cursor"].is_null());
}

async fn check_devices_inventory_query_matches_fixture(harness: &SrqlTestHarness) {
    let request = QueryRequest {
        query: "in:devices discovery_sources:(armis) include_inactive:true time:last_7d sort:last_seen:desc limit:2"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(status, http::StatusCode::OK);
    assert!(body.get("error").is_none(), "unexpected error body: {body}");
    let rows = body["results"]
        .as_array()
        .expect("results should be an array");
    assert_eq!(
        rows.len(),
        2,
        "limit:2 should constrain to two rows, got body: {body}"
    );

    let first = rows
        .first()
        .expect("rows should contain at least one entry")
        .as_object()
        .expect("row should be JSON object");
    assert_eq!(
        first.get("uid"),
        Some(&serde_json::Value::String("device-alpha".into()))
    );
    assert_eq!(
        first.get("discovery_sources"),
        Some(&serde_json::json!(["sweep", "armis"]))
    );
    assert_eq!(
        first.get("is_available"),
        Some(&serde_json::Value::Bool(true))
    );

    let second = rows[1].as_object().expect("row should be JSON object");
    assert_eq!(
        second.get("uid"),
        Some(&serde_json::Value::String("device-beta".into()))
    );
}

async fn check_invalid_field_returns_400(harness: &SrqlTestHarness) {
    let request = QueryRequest {
        query: "in:devices unsupported_field:foo".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(status, http::StatusCode::BAD_REQUEST);
    assert_eq!(
        body["error"],
        serde_json::json!("invalid request: unsupported filter field 'unsupported_field'")
    );
}

async fn check_missing_api_key_returns_401(harness: &SrqlTestHarness) {
    let request = QueryRequest {
        query: "in:devices limit:1".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query_without_api_key(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(status, http::StatusCode::UNAUTHORIZED);
    assert_eq!(body["error"], serde_json::json!("authentication failed"));
}

async fn check_device_graph_query_returns_neighborhood(harness: &SrqlTestHarness) {
    if !harness.age_available() {
        if allow_age_skip() {
            eprintln!("[srql-test] AGE not available in fixture; skipping device_graph test");
            return;
        }
        panic!("AGE not available in fixture and SRQL_ALLOW_AGE_SKIP not set");
    }

    let request = QueryRequest {
        query: r#"in:device_graph device_id:"device-alpha""#.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(status, http::StatusCode::OK, "unexpected status: {body}");
    let results = body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("results missing or not array: {body}"));
    assert_eq!(results.len(), 1, "expected single neighborhood row");
    let graph = results[0]
        .as_object()
        .unwrap_or_else(|| panic!("graph result is not an object: {body}"));

    let device = graph
        .get("device")
        .and_then(|d| d.get("id"))
        .and_then(|id| id.as_str())
        .unwrap_or_else(|| panic!("device id missing in graph result: {body}"));
    assert_eq!(device, "device-alpha");

    let collectors = graph
        .get("collectors")
        .and_then(|c| c.as_array())
        .unwrap_or_else(|| panic!("collectors missing or not array: {body}"));
    assert!(
        collectors
            .iter()
            .any(|c| c.get("id").and_then(|id| id.as_str()) == Some("serviceradar:agent:agent-1")),
        "expected collector serviceradar:agent:agent-1 in graph: {body}"
    );

    let services = graph
        .get("services")
        .and_then(|s| s.as_array())
        .unwrap_or_else(|| panic!("services missing or not array: {body}"));
    assert!(
        services.iter().any(|svc| {
            let svc_obj = svc.as_object().unwrap();
            svc_obj
                .get("collector_owned")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
                && svc_obj.get("collector_id").and_then(|v| v.as_str())
                    == Some("serviceradar:agent:agent-1")
                && svc_obj
                    .get("service")
                    .and_then(|p| p.get("id"))
                    .and_then(|id| id.as_str())
                    == Some("serviceradar:service:ssh@agent-1")
        }),
        "expected collector-owned service ssh@agent-1 in graph: {body}"
    );

    let interfaces = graph
        .get("interfaces")
        .and_then(|i| i.as_array())
        .unwrap_or_else(|| panic!("interfaces missing or not array: {body}"));
    assert!(
        interfaces
            .iter()
            .any(|iface| iface.get("id").and_then(|id| id.as_str()) == Some("device-alpha/eth0")),
        "expected interface device-alpha/eth0 in graph: {body}"
    );

    let peer_interfaces = graph
        .get("peer_interfaces")
        .and_then(|i| i.as_array())
        .unwrap_or_else(|| panic!("peer_interfaces missing or not array: {body}"));
    assert!(
        peer_interfaces.iter().any(|iface| {
            iface.get("id").and_then(|id| id.as_str()) == Some("device-beta/eth1")
                && iface.get("owner_device_id").and_then(|id| id.as_str()) == Some("device-beta")
                && iface
                    .get("owner_device")
                    .and_then(|device| device.get("hostname"))
                    .and_then(|hostname| hostname.as_str())
                    == Some("beta-edge")
        }),
        "expected peer interface owner data in graph: {body}"
    );

    let device_caps = graph
        .get("device_capabilities")
        .and_then(|c| c.as_array())
        .unwrap_or_else(|| panic!("device_capabilities missing or not array: {body}"));
    assert!(
        device_caps
            .iter()
            .any(|cap| cap.get("type").and_then(|t| t.as_str()) == Some("snmp")),
        "expected snmp capability in graph: {body}"
    );

    let filtered_request = QueryRequest {
        query: r#"in:device_graph device_id:"device-alpha" collector_owned:true include_topology:false"#
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let filtered_response = harness.query(filtered_request).await;
    let (filtered_status, filtered_body) = read_json(filtered_response).await;
    assert_eq!(
        filtered_status,
        http::StatusCode::OK,
        "unexpected status on filtered graph query: {filtered_body}"
    );
    let filtered_results = filtered_body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("filtered results missing or not array: {filtered_body}"));
    assert_eq!(filtered_results.len(), 1, "expected single filtered row");
    let filtered_graph = filtered_results[0]
        .as_object()
        .unwrap_or_else(|| panic!("filtered graph result is not an object: {filtered_body}"));

    let filtered_interfaces = filtered_graph
        .get("interfaces")
        .and_then(|i| i.as_array())
        .unwrap_or_else(|| panic!("interfaces missing or not array: {filtered_body}"));
    assert!(
        filtered_interfaces.is_empty(),
        "include_topology:false should omit interfaces: {filtered_body}"
    );
}

async fn check_device_graph_query_rejects_invalid_device_id(harness: &SrqlTestHarness) {
    let request = QueryRequest {
        query: r#"in:device_graph device_id:"device$$alpha""#.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(
        status,
        http::StatusCode::BAD_REQUEST,
        "unexpected status: {body}"
    );
    assert_eq!(
        body["error"],
        serde_json::json!("invalid request: device_id contains invalid character '$'")
    );
}

async fn check_timeseries_metrics_query_returns_rows(harness: &SrqlTestHarness) {
    let request = QueryRequest {
        query: r#"in:timeseries_metrics device_id:"device-alpha" time:last_1h sort:timestamp:desc"#
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(status, http::StatusCode::OK, "unexpected status: {body}");
    let rows = body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("results missing or not array: {body}"));
    assert!(
        !rows.is_empty(),
        "timeseries_metrics should return seeded rows for device-alpha: {body}"
    );
    assert!(
        rows.iter()
            .all(|row| row.get("uid").and_then(|v| v.as_str()) == Some("device-alpha")),
        "all rows should belong to device-alpha: {body}"
    );
}

async fn check_timeseries_other_rollup_returns_tail_row(harness: &SrqlTestHarness) {
    let request = QueryRequest {
        query: r#"in:timeseries_metrics time:last_1h stats:"sum(value) as total_value, count(*) as sample_count by device_id" sort:total_value:desc limit:1 other:true"#
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(status, http::StatusCode::OK, "unexpected status: {body}");
    let rows = body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("results missing or not array: {body}"));
    assert_eq!(rows.len(), 2, "expected top row plus Other row: {body}");
    assert_eq!(rows[0]["__other__"], serde_json::json!(false));
    assert_eq!(rows[0]["device_id"], serde_json::json!("device-alpha"));
    assert_eq!(rows[0]["sample_count"], serde_json::json!(2));
    assert_eq!(rows[1]["__other__"], serde_json::json!(true));
    assert_eq!(rows[1]["device_id"], serde_json::Value::Null);
    assert_eq!(rows[1]["sample_count"], serde_json::json!(1));
}

async fn check_timeseries_metrics_profile_hour_of_week(harness: &SrqlTestHarness) {
    let request = QueryRequest {
        query: r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:[2026-01-01T00:00:00Z,2026-02-01T00:00:00Z] stats:profile_hour_of_week(value) timezone:"Etc/UTC" sort:dow:asc,hod:asc limit:10"#
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(status, http::StatusCode::OK, "unexpected status: {body}");
    let rows = body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("results missing or not array: {body}"));
    let row = rows
        .iter()
        .find(|row| row.get("series").and_then(|value| value.as_str()) == Some("device-alpha"))
        .unwrap_or_else(|| panic!("device-alpha profile row missing: {body}"));

    assert_eq!(row["dow"], serde_json::json!(0));
    assert_eq!(row["hod"], serde_json::json!(3));
    assert_json_f64(row, "sample_value", 800.0);
    assert_eq!(row["bucket_count"], serde_json::json!(4));
    assert_json_f64(row, "bucket_sum", 830.0);
    assert_json_f64(row, "bucket_sum_sq", 640_302.0);
    assert_json_f64(row, "center", 10.0);
    assert_json_f64(row, "mad", 1.0);
    assert_json_f64(row, "p05", 9.1);
    assert_json_f64(row, "p95", 10.9);

    let sparse = rows
        .iter()
        .find(|row| row.get("series").and_then(|value| value.as_str()) == Some("device-sparse"))
        .unwrap_or_else(|| panic!("device-sparse profile row missing: {body}"));

    assert_eq!(sparse["dow"], serde_json::json!(0));
    assert_eq!(sparse["hod"], serde_json::json!(4));
    assert_json_f64(sparse, "sample_value", 123.0);
    assert_eq!(sparse["bucket_count"], serde_json::json!(1));
    assert_eq!(sparse["center"], serde_json::Value::Null);
    assert_eq!(sparse["mad"], serde_json::Value::Null);
    assert_eq!(sparse["p05"], serde_json::Value::Null);
    assert_eq!(sparse["p95"], serde_json::Value::Null);
}

fn assert_json_f64(row: &serde_json::Value, field: &str, expected: f64) {
    let actual = row
        .get(field)
        .and_then(|value| value.as_f64())
        .unwrap_or_else(|| panic!("{field} missing or not numeric in row: {row}"));

    assert!(
        (actual - expected).abs() < 0.000_001,
        "{field} expected {expected}, got {actual}; row: {row}"
    );
}

async fn check_snmp_metrics_alias_filters_metric_type(harness: &SrqlTestHarness) {
    let request = QueryRequest {
        query: r#"in:snmp_metrics device_id:"device-alpha" time:last_1h sort:timestamp:desc"#
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(status, http::StatusCode::OK, "unexpected status: {body}");
    let rows = body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("results missing or not array: {body}"));
    assert!(
        !rows.is_empty(),
        "snmp_metrics should return seeded snmp rows: {body}"
    );
    assert!(
        rows.iter()
            .all(|row| row.get("metric_type").and_then(|v| v.as_str()) == Some("snmp")),
        "snmp_metrics entity should enforce metric_type=snmp: {body}"
    );
}

async fn check_virtualization_inventory_queries(harness: &SrqlTestHarness) {
    let hosts = QueryRequest {
        query: r#"in:virtualization_hosts provider:proxmox cluster:lab node:pve-a time:last_1h sort:freshness:desc"#.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(hosts).await;
    let (status, body) = read_json(response).await;
    assert_eq!(
        status,
        http::StatusCode::OK,
        "unexpected hosts body: {body}"
    );
    let rows = body["results"].as_array().expect("results array");
    assert_eq!(rows.len(), 1, "expected one Proxmox host: {body}");
    assert_eq!(rows[0]["provider"], serde_json::json!("proxmox"));
    assert_eq!(rows[0]["node"], serde_json::json!("pve-a"));
    assert_eq!(rows[0]["cluster_name"], serde_json::json!("lab"));

    let guests = QueryRequest {
        query: "in:virtualization_guests provider:proxmox guest_type:vm vmid:100".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(guests).await;
    let (status, body) = read_json(response).await;
    assert_eq!(
        status,
        http::StatusCode::OK,
        "unexpected guests body: {body}"
    );
    let rows = body["results"].as_array().expect("results array");
    assert_eq!(rows.len(), 1, "expected one Proxmox guest: {body}");
    assert_eq!(rows[0]["vmid"], serde_json::json!(100));
    assert_eq!(rows[0]["host_name"], serde_json::json!("pve-a"));

    let datastores = QueryRequest {
        query: "in:virtualization_datastores provider:proxmox storage:local-zfs active:true"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(datastores).await;
    let (status, body) = read_json(response).await;
    assert_eq!(
        status,
        http::StatusCode::OK,
        "unexpected datastores body: {body}"
    );
    let rows = body["results"].as_array().expect("results array");
    assert_eq!(rows.len(), 1, "expected one Proxmox datastore: {body}");
    assert_eq!(rows[0]["storage"], serde_json::json!("local-zfs"));
    assert_eq!(rows[0]["total_bytes"], serde_json::json!(107374182400i64));

    let guest_nics = QueryRequest {
        query: r#"in:virtualization_network_interfaces provider:proxmox guest_provider_ref:"proxmox:guest:pve-a:qemu:100" mac:"52:54:00:aa:bb:cc" ip:"10.10.10.20/24""#.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(guest_nics).await;
    let (status, body) = read_json(response).await;
    assert_eq!(
        status,
        http::StatusCode::OK,
        "unexpected guest NIC body: {body}"
    );
    let rows = body["results"].as_array().expect("results array");
    assert_eq!(rows.len(), 1, "expected one Proxmox guest NIC: {body}");
    assert_eq!(rows[0]["guest_name"], serde_json::json!("vm-100"));
    assert_eq!(rows[0]["host_name"], serde_json::json!("pve-a"));
    assert_eq!(
        rows[0]["ip_addresses"],
        serde_json::json!(["10.10.10.20/24", "fe80::5054:ff:feaa:bbcc/64"])
    );

    let ceph = QueryRequest {
        query: "in:virtualization_storage_systems provider:proxmox storage_system_type:ceph ceph_health:HEALTH_WARN".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(ceph).await;
    let (status, body) = read_json(response).await;
    assert_eq!(status, http::StatusCode::OK, "unexpected ceph body: {body}");
    let rows = body["results"].as_array().expect("results array");
    assert_eq!(rows.len(), 1, "expected one Ceph row: {body}");
    assert_eq!(rows[0]["ceph_health"], serde_json::json!("HEALTH_WARN"));
}

async fn check_rperf_metrics_queries_still_work(harness: &SrqlTestHarness) {
    let request = QueryRequest {
        query: r#"in:rperf_metrics device_id:"device-beta" time:last_1h sort:timestamp:desc"#
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = harness.query(request).await;
    let (status, body) = read_json(response).await;

    assert_eq!(status, http::StatusCode::OK, "unexpected status: {body}");
    let rows = body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("results missing or not array: {body}"));
    assert!(
        !rows.is_empty(),
        "rperf_metrics should return seeded rows for device-beta: {body}"
    );
    assert!(
        rows.iter()
            .all(|row| row.get("metric_type").and_then(|v| v.as_str()) == Some("rperf")),
        "rperf_metrics should continue to enforce metric_type=rperf: {body}"
    );
}

fn allow_age_skip() -> bool {
    match std::env::var("SRQL_ALLOW_AGE_SKIP") {
        Ok(val) => !(val.trim().eq_ignore_ascii_case("false") || val.trim() == "0"),
        Err(_) => true, // default to skipping when AGE is unavailable
    }
}
