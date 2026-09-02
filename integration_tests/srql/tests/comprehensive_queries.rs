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
            query: "in:gateways status:active",
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
            query: "in:logs time:last_10m sort:timestamp:desc",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                assert_eq!(results[0]["body"], "Connection failed");
                assert_eq!(results[1]["body"], "Application started");
            })),
        },
        TestCase {
            query: "in:logs device_id:\"device-alpha\" time:last_10m",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["body"], "Application started");
                assert_eq!(body["results"][0]["source_device_uid"], "device-alpha");
            })),
        },
        TestCase {
            query: "in:logs source_ip:\"198.51.100.42\" time:last_10m",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["body"], "Application started");
                assert_eq!(body["results"][0]["source_ip"], "198.51.100.42");
            })),
        },
        TestCase {
            query: "in:events device_id:\"device-alpha\" class_uid:4001 time:last_10m",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["message"], "Device scoped event");
                assert_eq!(body["results"][0]["source_device_uid"], "device-alpha");
            })),
        },
        TestCase {
            query: "in:otel_traces service.name:api-service",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["name"], "handle_request")
            })),
        },
        TestCase {
            query: "in:endpoint_packages device_id:device-alpha package_manager:dpkg name:nginx current:true sort:name:asc",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["name"], "nginx");
                assert_eq!(result["device_uid"], "device-alpha");
                assert_eq!(result["device_id"], "device-alpha");
                assert_eq!(result["package_manager"], "dpkg");
                assert_eq!(result["current"], true);
                assert_eq!(
                    result["package_id"],
                    "aaaaaaaa-1111-4111-8111-111111111111"
                );
                assert_eq!(result["has_package"]["relation"], "HAS_PACKAGE");
                assert_eq!(result["has_package"]["device_uid"], "device-alpha");
            })),
        },
        TestCase {
            query: "in:endpoint_package_catalog canonical_purl:pkg:deb/nginx@1.24.0-2ubuntu7 cpe:cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:* source_scope:host",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["name"], "nginx");
                assert_eq!(result["package_id"], "aaaaaaaa-1111-4111-8111-111111111111");
                assert_eq!(result["canonical_purl"], "pkg:deb/nginx@1.24.0-2ubuntu7");
                assert_eq!(result["source_scope"], "host");
            })),
        },
        TestCase {
            query: "in:security_findings class_uid:2002 device_id:device-alpha canonical_purl:pkg:deb/nginx@1.24.0-2ubuntu7 cpe:cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:* cve:CVE-2026-0001",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["class_uid"], 2002);
                assert_eq!(result["source_device_uid"], "device-alpha");
                assert_eq!(result["metadata"]["primary_domain"], "security");
                assert_eq!(
                    result["metadata"]["vulnerability_finding"]["package"]["purl_canonical"],
                    "pkg:deb/nginx@1.24.0-2ubuntu7"
                );
            })),
        },
        TestCase {
            query: "in:endpoint_packages rollup_stats:current_counts package_manager:dpkg name:nginx",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["rollup_type"], "current_counts");
                assert_eq!(result["name"], "nginx");
                assert_eq!(result["package_manager"], "dpkg");
                assert_eq!(result["host_count"], 1);
            })),
        },
        TestCase {
            query: "in:endpoint_packages rollup_stats:current_cpe_counts cpe:cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["rollup_type"], "current_cpe_counts");
                assert_eq!(
                    result["cpe"],
                    "cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*"
                );
                assert_eq!(result["host_count"], 1);
            })),
        },
        TestCase {
            query: "in:endpoint_packages time:last_2h rollup_stats:package_counts_hourly package_manager:dpkg name:nginx",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["rollup_type"], "package_counts_hourly");
                assert_eq!(result["name"], "nginx");
                assert_eq!(result["host_count"], 1);
                assert_eq!(result["sample_count"], 1);
            })),
        },
        TestCase {
            query: "in:endpoint_inventory_status device_id:device-alpha current:true freshness:fresh package_set_hash:sha256:current-package-set",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["agent_id"], "agent-1");
                assert_eq!(result["device_uid"], "device-alpha");
                assert_eq!(result["package_set_hash"], "sha256:current-package-set");
                assert_eq!(result["unchanged_scan_count"], 0);
                assert_eq!(result["freshness_verdict"], "fresh");
                assert_eq!(result["freshness"]["verdict"], "fresh");
            })),
        },
        TestCase {
            query: "in:cves cve:CVE-2026-0001",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["cve_id"], "CVE-2026-0001");
                assert_eq!(result["kev"], true);
                assert_eq!(result["cvss_score"], 9.8);
                assert!(result.get("raw").is_none());
                assert!(result.get("affected_coordinates").is_none());
            })),
        },
        TestCase {
            query: "in:advisory_coordinates cve:CVE-2026-0001 coordinate_type:cpe",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["cve_id"], "CVE-2026-0001");
                assert_eq!(body["results"][0]["cpe_vendor"], "nginx");
                assert_eq!(body["results"][0]["cpe_product"], "nginx");
            })),
        },
        TestCase {
            query: "in:cve_matches cve:CVE-2026-0001",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["device_uid"], "device-alpha");
                assert_eq!(result["package_name"], "nginx");
                assert_eq!(result["kev"], true);
                assert_eq!(result["epss_score"], 0.84);
            })),
        },
        TestCase {
            query: "in:endpoint_packages cve:CVE-2026-0001 current:true",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["name"], "nginx");
                assert_eq!(body["results"][0]["device_uid"], "device-alpha");
            })),
        },
        TestCase {
            query: "in:devices kev:true",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-alpha");
            })),
        },
        TestCase {
            query: r#"in:packages cpe:"cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*" current:true"#,
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["purl"], "pkg:deb/nginx@1.24.0-2ubuntu7")
            })),
        },
        // Device Query Tests
        TestCase {
            // device-delta is 8 days old, so last_7d should exclude it.
            // device-alpha (30m), device-beta (3h), device-gamma (2h) should be included.
            // include_inactive:true keeps inactive device-beta visible.
            query: "in:devices include_inactive:true time:last_7d",
            expected_count: 3,
            validator: None,
        },
        TestCase {
            // Only device-alpha (30m) is within the last hour.
            query: "in:devices time:last_1h",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-alpha")
            })),
        },
        TestCase {
            // Sort by last_seen desc. device-alpha (30m) > gamma (2h) > beta (3h) > delta (8d)
            query: "in:devices include_inactive:true sort:last_seen:desc",
            expected_count: 4,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                assert_eq!(results[0]["uid"], "device-alpha");
                assert_eq!(results[1]["uid"], "device-gamma");
                assert_eq!(results[2]["uid"], "device-beta");
                assert_eq!(results[3]["uid"], "device-delta");
            })),
        },
        TestCase {
            // Sort by last_seen asc. delta (8d) < beta (3h) < gamma (2h) < alpha (30m)
            query: "in:devices include_inactive:true sort:last_seen:asc",
            expected_count: 4,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                assert_eq!(results[0]["uid"], "device-delta");
                assert_eq!(results[1]["uid"], "device-beta");
                assert_eq!(results[2]["uid"], "device-gamma");
                assert_eq!(results[3]["uid"], "device-alpha");
            })),
        },
        TestCase {
            // Limit 2. Should return top 2 based on default sort (last_seen desc) -> alpha, gamma
            query: "in:devices limit:2",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                assert_eq!(results[0]["uid"], "device-alpha");
                assert_eq!(results[1]["uid"], "device-gamma");
            })),
        },
        TestCase {
            // is_available:true -> alpha, gamma, delta
            query: "in:devices is_available:true",
            expected_count: 3,
            validator: None,
        },
        TestCase {
            // is_available:false -> beta (inactive, so include_inactive is needed)
            query: "in:devices include_inactive:true is_available:false",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-beta")
            })),
        },
        TestCase {
            // is_active:false -> beta remains queryable but is out of service
            query: "in:devices is_active:false",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-beta");
                assert_eq!(body["results"][0]["is_active"], false);
            })),
        },
        TestCase {
            // Per-agent latest availability: agent-1 sees alpha and beta as reachable.
            query: "in:devices include_inactive:true available_from_agent:agent-1 sort:uid:asc",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                let ids: Vec<&str> = results.iter().map(|r| r["uid"].as_str().unwrap()).collect();
                assert_eq!(ids, vec!["device-alpha", "device-beta"]);
            })),
        },
        TestCase {
            // Per-agent latest availability: agent-2 cannot reach alpha.
            query: "in:devices unavailable_from_agent:agent-2",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-alpha")
            })),
        },
        TestCase {
            query: "in:devices availability_source_agent_id:agent-1",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-alpha")
            })),
        },
        TestCase {
            query: "in:devices primary_availability_source:agent-1",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-alpha")
            })),
        },
        TestCase {
            query: "in:devices availability_source_fresh_within:last_1h",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-alpha")
            })),
        },
        TestCase {
            query: "in:devices availability_source_stale_after:last_10m",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-alpha")
            })),
        },
        // JSONB path queries for os field
        TestCase {
            // os.name:IOS-XE -> device-alpha only
            query: "in:devices os.name:IOS-XE",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-alpha")
            })),
        },
        TestCase {
            // os.name with LIKE pattern -> match devices with "OS" in os name
            // IOS-XE, NX-OS, PAN-OS, IOS all contain "OS"
            query: "in:devices include_inactive:true os.name:%OS%",
            expected_count: 4,
            validator: None,
        },
        TestCase {
            // os.version:17.9.3 -> device-alpha only
            query: "in:devices os.version:17.9.3",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["uid"], "device-alpha")
            })),
        },
        // JSONB path queries for metadata field
        TestCase {
            // metadata.site:dfw-edge -> device-alpha and device-beta
            query: "in:devices include_inactive:true metadata.site:dfw-edge",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                let ids: Vec<&str> = results.iter().map(|r| r["uid"].as_str().unwrap()).collect();
                assert!(ids.contains(&"device-alpha"));
                assert!(ids.contains(&"device-beta"));
            })),
        },
        TestCase {
            // metadata.packet_loss_bucket:low -> device-alpha and device-delta
            query: "in:devices metadata.packet_loss_bucket:low",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let results = body["results"].as_array().unwrap();
                let ids: Vec<&str> = results.iter().map(|r| r["uid"].as_str().unwrap()).collect();
                assert!(ids.contains(&"device-alpha"));
                assert!(ids.contains(&"device-delta"));
            })),
        },
        // Combined JSONB and scalar filters
        TestCase {
            // os.name with LIKE and is_available:true
            query: "in:devices os.name:%OS% is_available:true",
            expected_count: 3, // alpha, gamma, delta (beta is not available)
            validator: None,
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
