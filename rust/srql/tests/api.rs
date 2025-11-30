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
