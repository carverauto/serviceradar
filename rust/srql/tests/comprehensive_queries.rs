mod support;

use srql::query::{QueryDirection, QueryRequest};
use support::{read_json, with_srql_harness};

type BodyValidator = Box<dyn Fn(&serde_json::Value) + Send + Sync>;

struct TestCase<'a> {
    query: &'a str,
    expected_count: usize,
    validator: Option<BodyValidator>,
}

#[tokio::test(flavor = "multi_thread")]
async fn comprehensive_queries_match_fixtures() {
    let test_cases = vec![
        TestCase {
            query: "in:pollers status:active",
            expected_count: 2,
            validator: None,
        },
        TestCase {
            query: "in:services service_type:ssh",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["service_name"], "ssh")
            })),
        },
        TestCase {
            query: "in:cpu_metrics usage_percent:>88.1 usage_percent:<88.3",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["core_id"], 1)
            })),
        },
        TestCase {
            query: "in:logs severity_text:ERROR",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["body"], "Connection failed")
            })),
        },
        TestCase {
            query: "in:otel_traces service.name:api-service",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["name"], "handle_request")
            })),
        },
    ];

    with_srql_harness(|harness| async move {
        for case in test_cases {
            let request = QueryRequest {
                query: case.query.to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            };

            let response = harness.query(request).await;
            let (status, body) = read_json(response).await;

            assert_eq!(
                status,
                http::StatusCode::OK,
                "unexpected error for query '{}': {}",
                case.query,
                body
            );
            let rows = body["results"].as_array().unwrap_or_else(|| {
                panic!(
                    "'results' field is not an array or is missing. Body: {}",
                    body
                )
            });
            assert_eq!(
                rows.len(),
                case.expected_count,
                "Failed query count check: {}",
                case.query
            );
            if let Some(validate) = &case.validator {
                validate(&body);
            }
        }
    })
    .await;
}
