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
                assert_eq!(result["package_id"], "aaaaaaaa-1111-4111-8111-111111111111");
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
                assert_eq!(result["cpe"], "cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*");
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
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["device_uid"], "device-alpha");
                assert_eq!(result["package_name"], "nginx");
                assert_eq!(result["assessment"], "confirmed");
                assert_eq!(result["disposition"], "affected");
                assert_eq!(result["authority"], "Ubuntu");
                assert_eq!(result["freshness"], "fresh");
                assert_eq!(result["actionable"], true);
                assert_eq!(result["kev"], true);
                assert_eq!(result["epss_score"], 0.84);
            })),
        },
        TestCase {
            // With no lifecycle filter this is an audit/state-row count, not an
            // exposure count: confirmed, candidate, and resolved all contribute.
            query: "in:cve_matches stats:count() as n",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["n"], 3);
            })),
        },
        TestCase {
            query: "in:cve_matches status:active assessment:confirmed disposition:affected stats:count() as n",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["n"], 1);
            })),
        },
        TestCase {
            query: "in:endpoint_vulnerability_assessments status:resolved",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["device_uid"], "device-beta");
                assert_eq!(result["assessment"], "confirmed");
                assert_eq!(result["disposition"], "fixed");
                assert_eq!(result["actionable"], false);
            })),
        },
        TestCase {
            query: "in:package_vulnerabilities assessment:candidate freshness:unknown",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                let result = &body["results"][0];
                assert_eq!(result["device_uid"], "device-gamma");
                assert_eq!(result["disposition"], "unknown");
                assert_eq!(result["actionable"], false);
            })),
        },
        TestCase {
            query: r#"in:endpoint_vulnerability_assessments cpe:"%nginx:1.24.0%""#,
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["device_uid"], "device-alpha");
            })),
        },
        TestCase {
            // The candidate has two children: a CPE/openssl row and a PURL/curl row.
            // Predicates must never be satisfied by different child rows.
            query: "in:endpoint_vulnerability_assessments coordinate_type:cpe coordinate_value:%curl%",
            expected_count: 0,
            validator: None,
        },
        TestCase {
            query: "in:endpoint_vulnerability_assessments coordinate_type:cpe coordinate_value:%openssl%",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["device_uid"], "device-gamma");
            })),
        },
        TestCase {
            // device-alpha is backed by a raw match; device-gamma only reaches this
            // advisory through its authoritative package assertion.
            query: "in:endpoint_vulnerability_assessments advisory_ref:bbbbbbbb-1111-4111-8111-111111111111",
            expected_count: 2,
            validator: None,
        },
        TestCase {
            // A package assertion can satisfy advisory_ref by itself, but it cannot
            // make raw-coordinate predicates true for that advisory.
            query: "in:endpoint_vulnerability_assessments advisory_ref:bbbbbbbb-1111-4111-8111-111111111111 coordinate_type:cpe coordinate_value:%openssl%",
            expected_count: 0,
            validator: None,
        },
        TestCase {
            query: "in:endpoint_vulnerability_assessments !advisory_ref:bbbbbbbb-1111-4111-8111-111111111111",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["device_uid"], "device-beta");
            })),
        },
        TestCase {
            query: "in:endpoint_vulnerability_assessments authority_generation:7",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["device_uid"], "device-alpha");
            })),
        },
        TestCase {
            query: "in:endpoint_vulnerability_assessments authority_as_of:>2020-01-01T00:00:00Z",
            expected_count: 2,
            validator: None,
        },
        TestCase {
            query: "in:endpoint_vulnerability_assessments !authority_generation:999 !authority_as_of:1999-01-01T00:00:00Z",
            expected_count: 3,
            validator: None,
        },
        TestCase {
            // NULL historical refs are distinct from the excluded UUID and must survive NotEq.
            query: "in:endpoint_vulnerability_assessments !scan_ref:99999999-9999-4999-8999-999999999999",
            expected_count: 3,
            validator: None,
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
            query: "in:endpoint_packages kev:true current:true",
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
            // Inventory spans both devices even though only alpha has a confirmed assessment.
            query: r#"in:packages cpe:"cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*" current:true"#,
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let mut packages: Vec<_> = body["results"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|row| (row["device_uid"].as_str().unwrap(), row["purl"].as_str().unwrap()))
                    .collect();
                packages.sort_unstable();
                assert_eq!(
                    packages,
                    vec![
                        ("device-alpha", "pkg:deb/nginx@1.24.0-2ubuntu7"),
                        ("device-gamma", "pkg:deb/nginx@1.24.0-2ubuntu7"),
                    ]
                );
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
        // -- identity reconciliation diagnostics (GitHub #4229) ------------
        TestCase {
            query: "in:merge_audit device_id:identity-src",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["to_device_id"], "identity-mid");
                assert_eq!(body["results"][0]["reason"], "duplicate_mac");
                // The allowlist keeps declared keys and drops everything else.
                assert_eq!(
                    body["results"][0]["details"]["source"],
                    "scheduled_reconciliation"
                );
                assert!(
                    body["results"][0]["details"]["secret_token"].is_null(),
                    "details allowlist leaked an undeclared key: {}",
                    body["results"][0]["details"]
                );
            })),
        },
        TestCase {
            // The unmerge row between comp-a and comp-b is hidden by default.
            query: "in:merge_audit device_id:identity-comp-a",
            expected_count: 0,
            validator: None,
        },
        TestCase {
            query: "in:merge_audit device_id:identity-comp-a include_unmerge:true",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["reason"], "unmerge");
            })),
        },
        TestCase {
            // Three hops forward: src -> mid -> survivor is two edges.
            query: "in:merge_audit chain:identity-src",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let rows = body["results"].as_array().unwrap();
                assert!(rows.iter().all(|row| row["direction"] == "merged_into"));
                let deepest = rows.iter().max_by_key(|row| row["depth"].as_i64()).unwrap();
                assert_eq!(deepest["to_device_id"], "identity-survivor");
                assert_eq!(deepest["depth"], 2);
                assert_eq!(rows[0]["truncated"], false);
            })),
        },
        TestCase {
            // Backward from the survivor: what came into it.
            query: "in:merge_audit chain:identity-survivor",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let rows = body["results"].as_array().unwrap();
                assert!(rows.iter().all(|row| row["direction"] == "merged_from"));
            })),
        },
        TestCase {
            // Four merge rows between the same two devices, in both directions.
            // A walk without a visited-set guard does not terminate on this, and
            // one keyed on (event_id, direction) returns each row twice.
            query: "in:merge_audit chain:identity-osc-a",
            expected_count: 4,
            validator: Some(Box::new(|body| {
                let rows = body["results"].as_array().unwrap();
                assert!(
                    rows.iter().all(|row| row["depth"].as_i64().unwrap() <= 2),
                    "oscillating pair should not accumulate depth: {}",
                    body["results"]
                );
                let ids: std::collections::HashSet<_> =
                    rows.iter().map(|row| row["event_id"].clone()).collect();
                assert_eq!(
                    ids.len(),
                    rows.len(),
                    "each audit row must appear once, not once per direction"
                );
            })),
        },
        TestCase {
            query: "in:device_revival_audit device_uid:identity-revived",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                // The tombstone the revival destroyed is what makes this useful.
                assert_eq!(
                    body["results"][0]["previous_deleted_reason"],
                    "phantom apipa address"
                );
                assert_eq!(body["results"][0]["previous_deleted_by"], "operator");
                assert_eq!(
                    body["results"][0]["revived_by_application"],
                    "serviceradar-core"
                );
            })),
        },
        TestCase {
            query: "in:device_identifiers device_id:identity-survivor identifier_type:mac",
            expected_count: 3,
            validator: Some(Box::new(|body| {
                let rows = body["results"].as_array().unwrap();
                let corroborated = rows
                    .iter()
                    .filter(|row| row["matches_current_facts"] == true)
                    .count();
                // The current `mac` column AND the interface MAC both count;
                // the third value is only history.
                assert_eq!(corroborated, 2, "rows: {}", body["results"]);
                assert!(
                    rows.iter().any(|row| row["identifier_value"] == "AABBCCDEAD01"
                        && row["matches_current_facts"] == false),
                    "a historical MAC must still be returned, marked false"
                );
                assert!(
                    rows.iter().all(|row| row["metadata"]["secret_token"].is_null()),
                    "metadata allowlist leaked an undeclared key"
                );
            })),
        },
        TestCase {
            query: "in:device_identifiers device_id:identity-survivor identifier_type:armis_device_id",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                // Null, not false. Reporting an external system's key as false
                // would assert it is stale, which is a different and wrong claim.
                assert!(
                    body["results"][0]["matches_current_facts"].is_null(),
                    "an armis_device_id has no comparable current fact: {}",
                    body["results"][0]
                );
            })),
        },
        TestCase {
            query: "in:device_identifiers value:AABBCC00DEAD",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                // The owner is tombstoned; the identifier row still surfaces,
                // carrying the owner's tombstone.
                assert_eq!(body["results"][0]["device_id"], "identity-src");
                assert_eq!(body["results"][0]["owner_deleted"], true);
                assert_eq!(
                    body["results"][0]["owner_deleted_reason"],
                    "merged into identity-survivor"
                );
            })),
        },
        TestCase {
            // A live owner, and a MAC written with colons on the device but
            // without them on the identifier: the projection normalises both
            // sides, so this is the case that proves it does. Hung off the
            // pre-existing device-alpha because every identity fixture device is
            // tombstoned to stay out of the shared device totals.
            query: "in:device_identifiers device_id:device-alpha identifier_type:mac",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["matches_current_facts"], true);
                assert_eq!(body["results"][0]["owner_deleted"], false);
                assert_eq!(body["results"][0]["owner_hostname"], "alpha-edge");
            })),
        },
        TestCase {
            // A -- B -- C: A-B is direct evidence, B-C is transitive from A,
            // and there is no A-C edge because they share no identifier.
            query: "in:identity_evidence_edges device:identity-comp-a",
            expected_count: 2,
            validator: Some(Box::new(|body| {
                let rows = body["results"].as_array().unwrap();

                let direct: Vec<_> = rows.iter().filter(|row| row["direct"] == true).collect();
                assert_eq!(direct.len(), 1, "rows: {}", body["results"]);
                assert_eq!(direct[0]["device_b"], "identity-comp-b");
                assert_eq!(direct[0]["depth"], 1);

                let transitive: Vec<_> =
                    rows.iter().filter(|row| row["direct"] == false).collect();
                assert_eq!(transitive.len(), 1);
                assert_eq!(transitive[0]["device_a"], "identity-comp-b");
                assert_eq!(transitive[0]["device_b"], "identity-comp-c");

                assert!(
                    !rows.iter().any(|row| {
                        row["device_a"] == "identity-comp-a"
                            && row["device_b"] == "identity-comp-c"
                    }),
                    "A and C share no identifier and must not be joined by an edge"
                );

                // comp-c lives in partition edge-west; the B-C edge crosses.
                assert_eq!(transitive[0]["cross_partition"], true);
                assert_eq!(direct[0]["cross_partition"], false);
            })),
        },
        TestCase {
            query: "in:identity_reconciliation_runs merge_cap_reached:true",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                assert_eq!(body["results"][0]["merges"], 200);
                assert_eq!(body["results"][0]["max_merges_configured"], 200);
                assert_eq!(body["results"][0]["largest_blocked_component"], 5);
                assert_eq!(body["results"][0]["blocked_components"], 4);
                let blocked = &body["results"][0]["blocked_component_devices"];
                assert_eq!(blocked[0]["device_ids"][0], "identity-comp-a");
            })),
        },
        TestCase {
            query: "in:dire_runs status:failed",
            expected_count: 1,
            validator: Some(Box::new(|body| {
                // A run that raised leaves a record rather than nothing at all.
                assert!(
                    body["results"][0]["error_summary"]
                        .as_str()
                        .unwrap()
                        .contains("serialization_failure")
                );
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
