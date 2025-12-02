mod support;

use serial_test::serial;
use support::{read_json, with_srql_harness};

use srql::query::{QueryDirection, QueryRequest};

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn devices_inventory_query_matches_fixture() {
    with_srql_harness(|harness| async move {
        let request = QueryRequest {
            query: "in:devices discovery_sources:(armis) time:last_7d sort:last_seen:desc limit:2"
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
            first.get("device_id"),
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
            second.get("device_id"),
            Some(&serde_json::Value::String("device-beta".into()))
        );
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn invalid_field_returns_400() {
    with_srql_harness(|harness| async move {
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
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn missing_api_key_returns_401() {
    with_srql_harness(|harness| async move {
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
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn device_graph_query_returns_neighborhood() {
    with_srql_harness(|harness| async move {
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
            collectors.iter().any(|c| c
                .get("id")
                .and_then(|id| id.as_str())
                == Some("serviceradar:agent:agent-1")),
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
            interfaces.iter().any(|iface| iface
                .get("id")
                .and_then(|id| id.as_str())
                == Some("device-alpha/eth0")),
            "expected interface device-alpha/eth0 in graph: {body}"
        );

        let device_caps = graph
            .get("device_capabilities")
            .and_then(|c| c.as_array())
            .unwrap_or_else(|| panic!("device_capabilities missing or not array: {body}"));
        assert!(
            device_caps.iter().any(|cap| cap
                .get("type")
                .and_then(|t| t.as_str())
                == Some("snmp")),
            "expected snmp capability in graph: {body}"
        );

        let filtered_request = QueryRequest {
            query: r#"in:device_graph device_id:"device-alpha" collector_owned:true include_topology:false"#.to_string(),
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
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn timeseries_metrics_query_returns_rows() {
    with_srql_harness(|harness| async move {
        let request = QueryRequest {
            query:
                r#"in:timeseries_metrics device_id:"device-alpha" time:last_1h sort:timestamp:desc"#
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
                .all(|row| row.get("device_id").and_then(|v| v.as_str()) == Some("device-alpha")),
            "all rows should belong to device-alpha: {body}"
        );
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn snmp_metrics_alias_filters_metric_type() {
    with_srql_harness(|harness| async move {
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
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn rperf_metrics_queries_still_work() {
    with_srql_harness(|harness| async move {
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
    })
    .await;
}

fn allow_age_skip() -> bool {
    std::env::var("SRQL_ALLOW_AGE_SKIP")
        .map(|v| v.trim().eq_ignore_ascii_case("true") || v == "1")
        .unwrap_or(false)
}
