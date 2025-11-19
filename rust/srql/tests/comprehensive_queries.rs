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
        // Device Query Tests
        TestCase {
            // device-delta is 8 days old, so last_7d should exclude it.
            // device-alpha (30m), device-beta (3h), device-gamma (2h) should be included.
            query: "in:devices time:last_7d",
            expected_count: 3,
            validator: None,
        },
        TestCase {
            // Only device-alpha (30m) is within the last hour.
            query: "in:devices time:last_1h",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["device_id"], "device-alpha")
            })),
        },
        TestCase {
            // Sort by last_seen desc. device-alpha (30m) > gamma (2h) > beta (3h) > delta (8d)
            query: "in:devices sort:last_seen:desc",
            expected_count: 4,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                assert_eq!(results[0]["device_id"], "device-alpha");
                assert_eq!(results[1]["device_id"], "device-gamma");
                assert_eq!(results[2]["device_id"], "device-beta");
                assert_eq!(results[3]["device_id"], "device-delta");
            })),
        },
        TestCase {
            // Sort by last_seen asc. delta (8d) < beta (3h) < gamma (2h) < alpha (30m)
            query: "in:devices sort:last_seen:asc",
            expected_count: 4,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                assert_eq!(results[0]["device_id"], "device-delta");
                assert_eq!(results[1]["device_id"], "device-beta");
                assert_eq!(results[2]["device_id"], "device-gamma");
                assert_eq!(results[3]["device_id"], "device-alpha");
            })),
        },
        TestCase {
            // Limit 2. Should return top 2 based on default sort (last_seen desc) -> alpha, gamma
            query: "in:devices limit:2",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                assert_eq!(results[0]["device_id"], "device-alpha");
                assert_eq!(results[1]["device_id"], "device-gamma");
            })),
        },
        TestCase {
            // is_available:true -> alpha, gamma, delta
            query: "in:devices is_available:true",
            expected_count: 3,
            validator: None,
        },
        TestCase {
            // is_available:false -> beta
            query: "in:devices is_available:false",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["device_id"], "device-beta")
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
