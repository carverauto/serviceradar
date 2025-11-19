mod support;

use support::{read_json, with_srql_harness};
use srql::query::{QueryDirection, QueryRequest};

#[tokio::test(flavor = "multi_thread")]
async fn pollers_query_matches_fixture() {
    with_srql_harness(|harness| async move {
        let request = QueryRequest {
            query: "in:pollers status:active".to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = harness.query(request).await;
        let (status, body) = read_json(response).await;

        assert_eq!(status, http::StatusCode::OK);
        let rows = body["results"].as_array().expect("results should be an array");
        assert_eq!(rows.len(), 2);
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn services_query_matches_fixture() {
    with_srql_harness(|harness| async move {
        let request = QueryRequest {
            query: "in:services service_type:ssh".to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = harness.query(request).await;
        let (status, body) = read_json(response).await;

        assert_eq!(status, http::StatusCode::OK);
        let rows = body["results"].as_array().expect("results should be an array");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["service_name"], "ssh");
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn cpu_metrics_query_matches_fixture() {
    with_srql_harness(|harness| async move {
        let request = QueryRequest {
            query: "in:cpu_metrics usage_percent:88.2".to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = harness.query(request).await;
        let (status, body) = read_json(response).await;

        assert_eq!(status, http::StatusCode::OK, "unexpected error: {body}");
        let rows = body["results"].as_array().expect("results should be an array");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["core_id"], 1);
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn logs_query_matches_fixture() {
    with_srql_harness(|harness| async move {
        let request = QueryRequest {
            query: "in:logs severity_text:ERROR".to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = harness.query(request).await;
        let (status, body) = read_json(response).await;

        assert_eq!(status, http::StatusCode::OK);
        let rows = body["results"].as_array().expect("results should be an array");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["body"], "Connection failed");
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn otel_traces_query_matches_fixture() {
    with_srql_harness(|harness| async move {
        let request = QueryRequest {
            query: "in:otel_traces service.name:api-service".to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };

        let response = harness.query(request).await;
        let (status, body) = read_json(response).await;

        assert_eq!(status, http::StatusCode::OK);
        let rows = body["results"].as_array().expect("results should be an array");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["name"], "handle_request");
    })
    .await;
}
