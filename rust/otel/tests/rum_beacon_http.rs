use std::io::Write;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};

use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper::header::{self, HeaderMap, HeaderValue};
use hyper::{Method, StatusCode};
use otel::ServiceRadarCollector;
use otel::config::RumConfig;
use otel::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use otel::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use otel::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;
use otel::output::{IngestContext, PerformanceMetric, PublishOutcome, TelemetryOutput};
use otel::rum::policy::RumPolicyCache;
use otel::rum::{RumRuntime, handle_rum_request};
use otel::rum_proto::{
    RumBeaconV1, RumPrefixTagRule, WebPropertyRumPolicy, WebPropertyRumPolicySnapshot,
};
use serviceradar_metric_proto::pb::MetricBatch;

#[derive(Default)]
struct RecordingOutput {
    beacon_publish_error: Option<&'static str>,
    beacons: Mutex<Vec<(String, RumBeaconV1)>>,
    metrics: Mutex<Vec<(String, MetricBatch)>>,
}

#[tonic::async_trait]
impl TelemetryOutput for RecordingOutput {
    async fn publish_traces(
        &self,
        _traces: &ExportTraceServiceRequest,
        _ctx: &IngestContext,
    ) -> anyhow::Result<PublishOutcome> {
        Ok(PublishOutcome::default())
    }

    async fn publish_logs(
        &self,
        _logs: &ExportLogsServiceRequest,
        _ctx: &IngestContext,
    ) -> anyhow::Result<PublishOutcome> {
        Ok(PublishOutcome::default())
    }

    async fn publish_raw_metrics(
        &self,
        _metrics: &ExportMetricsServiceRequest,
        _ctx: &IngestContext,
    ) -> anyhow::Result<PublishOutcome> {
        Ok(PublishOutcome::default())
    }

    async fn publish_derived_metrics(
        &self,
        _metrics: &[PerformanceMetric],
        _ctx: &IngestContext,
    ) -> anyhow::Result<PublishOutcome> {
        Ok(PublishOutcome::default())
    }

    async fn publish_rum_beacon(
        &self,
        web_property_id: &str,
        beacon: &RumBeaconV1,
    ) -> anyhow::Result<PublishOutcome> {
        if let Some(err) = self.beacon_publish_error {
            anyhow::bail!(err);
        }
        self.beacons
            .lock()
            .unwrap()
            .push((web_property_id.to_string(), beacon.clone()));
        Ok(PublishOutcome {
            published: 1,
            rejected: 0,
        })
    }

    async fn publish_rum_metrics(
        &self,
        web_property_id: &str,
        metrics: &MetricBatch,
    ) -> anyhow::Result<PublishOutcome> {
        self.metrics
            .lock()
            .unwrap()
            .push((web_property_id.to_string(), metrics.clone()));
        Ok(PublishOutcome {
            published: 1,
            rejected: 0,
        })
    }
}

fn test_snapshot() -> WebPropertyRumPolicySnapshot {
    WebPropertyRumPolicySnapshot {
        version: 10,
        generated_at_unix_ms: 0,
        properties: vec![
            WebPropertyRumPolicy {
                web_property_id: "01JWEBPROP0000000000000001".to_string(),
                name: "storefront".to_string(),
                canonical_origin: "https://shop.example".to_string(),
                allowed_origins: vec![
                    "https://shop.example".to_string(),
                    "https://*.shop.example".to_string(),
                ],
                allowed_query_keys: vec!["lang".to_string()],
                trace_propagate_origins: vec!["https://api.shop.example".to_string()],
                rum_site_key: "sr_rum_live_storefront".to_string(),
                rum_enabled: true,
                rum_sample_rate: 1.0,
                anonymize_client_ip: true,
                environment: "production".to_string(),
                prefix_tags: vec![RumPrefixTagRule {
                    cidr: "198.51.100.0/24".to_string(),
                    tag: "lab-corp".to_string(),
                }],
            },
            WebPropertyRumPolicy {
                web_property_id: "01JWEBPROP0000000000000002".to_string(),
                name: "disabled-prop".to_string(),
                canonical_origin: "https://off.example".to_string(),
                allowed_origins: vec!["https://off.example".to_string()],
                allowed_query_keys: vec![],
                trace_propagate_origins: vec![],
                rum_site_key: "sr_rum_live_disabled".to_string(),
                rum_enabled: false,
                rum_sample_rate: 1.0,
                anonymize_client_ip: true,
                environment: "staging".to_string(),
                prefix_tags: vec![],
            },
        ],
        global_prefix_tags: vec![RumPrefixTagRule {
            cidr: "203.0.113.0/24".to_string(),
            tag: "partner-edge".to_string(),
        }],
    }
}

fn make_runtime(config: RumConfig) -> RumRuntime {
    RumRuntime::new(
        config,
        Arc::new(RumPolicyCache::from_snapshot(test_snapshot())),
    )
}

#[tokio::test]
async fn beacon_gate_enforces_keys_origins_methods_and_payload_limits() {
    let output = Arc::new(RecordingOutput::default());
    let collector = ServiceRadarCollector::with_output(output.clone());
    let runtime = make_runtime(RumConfig {
        per_key_rps: 100.0,
        per_key_burst: 100.0,
        per_subnet_rps: 100.0,
        per_subnet_burst: 100.0,
        ..RumConfig::default()
    });

    // GET -> 405
    let resp = handle_rum_request(
        &Method::GET,
        None,
        &HeaderMap::new(),
        Full::new(Bytes::new()),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp.status(), StatusCode::METHOD_NOT_ALLOWED);

    // Unknown key -> 401
    let mut headers = HeaderMap::new();
    headers.insert(
        header::ORIGIN,
        HeaderValue::from_static("https://shop.example"),
    );
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/x-www-form-urlencoded"),
    );
    let resp = handle_rum_request(
        &Method::POST,
        None,
        &headers,
        Full::new(Bytes::from_static(
            b"sr.key=sr_rum_live_unknown&u=https%3A%2F%2Fshop.example%2F",
        )),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // Disabled property -> 403
    let mut off_headers = HeaderMap::new();
    off_headers.insert(
        header::ORIGIN,
        HeaderValue::from_static("https://off.example"),
    );
    off_headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/x-www-form-urlencoded"),
    );
    let resp = handle_rum_request(
        &Method::POST,
        None,
        &off_headers,
        Full::new(Bytes::from_static(
            b"sr.key=sr_rum_live_disabled&u=https%3A%2F%2Foff.example%2F",
        )),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // Disallowed Origin -> 403
    let mut evil_headers = HeaderMap::new();
    evil_headers.insert(
        header::ORIGIN,
        HeaderValue::from_static("https://evil.example"),
    );
    evil_headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/x-www-form-urlencoded"),
    );
    let resp = handle_rum_request(
        &Method::POST,
        None,
        &evil_headers,
        Full::new(Bytes::from_static(
            b"sr.key=sr_rum_live_storefront&u=https%3A%2F%2Fshop.example%2F",
        )),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // Valid OPTIONS preflight -> 204 with exact Origin, never *
    let preflight = handle_rum_request(
        &Method::OPTIONS,
        Some("key=sr_rum_live_storefront"),
        &headers,
        Full::new(Bytes::new()),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(preflight.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        preflight
            .headers()
            .get(header::ACCESS_CONTROL_ALLOW_ORIGIN)
            .unwrap(),
        "https://shop.example"
    );
    assert_eq!(preflight.headers().get(header::VARY).unwrap(), "Origin");

    // Raw body > 64 KiB -> 413
    let oversized = vec![b'a'; 65_537];
    let resp = handle_rum_request(
        &Method::POST,
        None,
        &headers,
        Full::new(Bytes::from(oversized)),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);

    // Gzip bomb (small wire, >64 KiB decompressed) -> 413
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
    encoder.write_all(&vec![b'b'; 70_000]).unwrap();
    let gz_bytes = Bytes::from(encoder.finish().unwrap());
    let mut gz_headers = headers.clone();
    gz_headers.insert(header::CONTENT_ENCODING, HeaderValue::from_static("gzip"));
    let resp = handle_rum_request(
        &Method::POST,
        None,
        &gz_headers,
        Full::new(gz_bytes),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn enrichment_and_trusted_proxy_gating_scrub_and_publish_beacon_and_metrics() {
    let output = Arc::new(RecordingOutput::default());
    let collector = ServiceRadarCollector::with_output(output.clone());
    let runtime = make_runtime(RumConfig {
        trusted_proxies: vec!["192.0.2.0/24".to_string()],
        ..RumConfig::default()
    });

    // 1. Untrusted peer tries to spoof True-Client-IP & Akamai-Edgescape -> ignored!
    let mut spoof_headers = HeaderMap::new();
    spoof_headers.insert(
        header::ORIGIN,
        HeaderValue::from_static("https://us.shop.example"),
    );
    spoof_headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    spoof_headers.insert("true-client-ip", HeaderValue::from_static("198.51.100.77"));
    spoof_headers.insert(
        "akamai-edgescape",
        HeaderValue::from_static(
            "country_code=US,region_code=CA,city=SANJOSE,asnum=64512,network=SPOOF",
        ),
    );
    let json_body = serde_json::json!({
        "sr.key": "sr_rum_live_storefront",
        "u": "https://us.shop.example/orders/987654?token=secret&lang=en#frag",
        "r": "https://ref.example/login?code=abc",
        "c.lcp": 1420.5,
        "c.inp": 48.0,
        "c.cls": 0.04,
        "servertiming": "cdn-cache;desc=HIT,edge;dur=12.4,origin;dur=55.2,ak_p;desc=iad-01",
        "sr.trace_id": "0123456789abcdef0123456789abcdef",
        "sr.span_id": "0123456789abcdef"
    })
    .to_string();

    let resp = handle_rum_request(
        &Method::POST,
        None,
        &spoof_headers,
        Full::new(Bytes::from(json_body.clone())),
        Some("203.0.113.42".parse::<IpAddr>().unwrap()),
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    {
        let beacons = output.beacons.lock().unwrap();
        assert_eq!(beacons.len(), 1);
        let (prop_id, b) = &beacons[0];
        assert_eq!(prop_id, "01JWEBPROP0000000000000001");
        // Untrusted peer uses peer IP (203.0.113.42 -> global prefix_tag partner-edge, then truncated to 203.0.113.0)
        assert_eq!(b.client_ip, "203.0.113.0");
        assert_eq!(b.prefix_tag, "partner-edge");
        assert_eq!(b.country, ""); // spoofed Akamai-Edgescape ignored!
        assert_eq!(b.url, "https://us.shop.example/orders/987654?lang=en");
        assert_eq!(b.referrer, "https://ref.example/login");
        assert_eq!(b.metric_path, "/orders/:id");
        assert_eq!(b.cdn_cache_status, "HIT");
        assert_eq!(b.cdn_edge_rtt_ms, Some(12.4));
        assert_eq!(b.cdn_origin_rtt_ms, Some(55.2));
        assert_eq!(b.cdn_pop, "iad-01");
        assert_eq!(b.trace_id, "0123456789abcdef0123456789abcdef");
        assert_eq!(b.span_id, "0123456789abcdef");
    }

    {
        let metric_batches = output.metrics.lock().unwrap();
        assert_eq!(metric_batches.len(), 1);
        assert_eq!(metric_batches[0].0, "01JWEBPROP0000000000000001");
        assert!(
            metric_batches[0]
                .1
                .metrics
                .iter()
                .any(|m| m.name == "rum.lcp_ms" && m.metric_type == "rum")
        );
        assert!(
            metric_batches[0]
                .1
                .metrics
                .iter()
                .any(|m| m.name == "rum.akamai_edge_rtt_ms" && m.metric_type == "rum")
        );
    }

    // 2. Trusted proxy (192.0.2.10 in 192.0.2.0/24) honors True-Client-IP & Akamai-Edgescape
    let resp2 = handle_rum_request(
        &Method::POST,
        None,
        &spoof_headers,
        Full::new(Bytes::from(json_body)),
        Some("192.0.2.10".parse::<IpAddr>().unwrap()),
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp2.status(), StatusCode::NO_CONTENT);

    let beacons = output.beacons.lock().unwrap();
    assert_eq!(beacons.len(), 2);
    let (_, b2) = &beacons[1];
    assert_eq!(b2.client_ip, "198.51.100.0");
    assert_eq!(b2.prefix_tag, "lab-corp");
    assert_eq!(b2.country, "US");
    assert_eq!(b2.asn, 64512);
    assert_eq!(b2.as_org, "SPOOF");
}

#[tokio::test]
async fn rate_limiter_returns_429_with_retry_after() {
    let output = Arc::new(RecordingOutput::default());
    let collector = ServiceRadarCollector::with_output(output);
    let runtime = make_runtime(RumConfig {
        per_key_rps: 1.0,
        per_key_burst: 1.0,
        per_subnet_rps: 100.0,
        per_subnet_burst: 100.0,
        ..RumConfig::default()
    });

    let mut headers = HeaderMap::new();
    headers.insert(
        header::ORIGIN,
        HeaderValue::from_static("https://shop.example"),
    );
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/x-www-form-urlencoded"),
    );

    let r1 = handle_rum_request(
        &Method::POST,
        None,
        &headers,
        Full::new(Bytes::from_static(
            b"sr.key=sr_rum_live_storefront&u=https%3A%2F%2Fshop.example%2F",
        )),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(r1.status(), StatusCode::NO_CONTENT);

    let r2 = handle_rum_request(
        &Method::POST,
        None,
        &headers,
        Full::new(Bytes::from_static(
            b"sr.key=sr_rum_live_storefront&u=https%3A%2F%2Fshop.example%2F",
        )),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(r2.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(r2.headers().get(header::RETRY_AFTER).is_some());
}

#[tokio::test]
async fn publish_failure_returns_generic_503_without_internal_error_text() {
    let output = Arc::new(RecordingOutput {
        beacon_publish_error: Some(
            "jetstream stream RUM_BEACONS unavailable at nats://nats.internal.example:4222",
        ),
        ..RecordingOutput::default()
    });
    let collector = ServiceRadarCollector::with_output(output.clone());
    let runtime = make_runtime(RumConfig::default());

    let mut headers = HeaderMap::new();
    headers.insert(
        header::ORIGIN,
        HeaderValue::from_static("https://shop.example"),
    );
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/x-www-form-urlencoded"),
    );

    let resp = handle_rum_request(
        &Method::POST,
        None,
        &headers,
        Full::new(Bytes::from_static(
            b"sr.key=sr_rum_live_storefront&u=https%3A%2F%2Fshop.example%2F",
        )),
        None,
        &runtime,
        &collector,
    )
    .await;

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let body = String::from_utf8(body.to_vec()).unwrap();
    assert!(!body.is_empty());
    assert!(!body.contains("jetstream"), "{body}");
    assert!(!body.contains("nats"), "{body}");
    assert!(output.beacons.lock().unwrap().is_empty());
}

#[tokio::test]
async fn ipv6_non_default_ports_uppercase_multipart_boundary_and_javascript_rejection() {
    let snapshot = WebPropertyRumPolicySnapshot {
        version: 1,
        generated_at_unix_ms: 0,
        properties: vec![
            WebPropertyRumPolicy {
                web_property_id: "01JWEBPROP0000000000000010".to_string(),
                name: "ipv6-storefront".to_string(),
                canonical_origin: "https://[2001:db8::1]:8443".to_string(),
                allowed_origins: vec!["https://[2001:db8::1]:8443".to_string()],
                allowed_query_keys: vec!["page".to_string()],
                trace_propagate_origins: vec![],
                rum_site_key: "sr_rum_live_ipv6_port".to_string(),
                rum_enabled: true,
                rum_sample_rate: 1.0,
                anonymize_client_ip: true,
                environment: "production".to_string(),
                prefix_tags: vec![],
            },
            WebPropertyRumPolicy {
                web_property_id: "01JWEBPROP0000000000000011".to_string(),
                name: "port-storefront".to_string(),
                canonical_origin: "https://shop.example:8443".to_string(),
                allowed_origins: vec!["https://shop.example:8443".to_string()],
                allowed_query_keys: vec!["page".to_string()],
                trace_propagate_origins: vec![],
                rum_site_key: "sr_rum_live_port8443".to_string(),
                rum_enabled: true,
                rum_sample_rate: 1.0,
                anonymize_client_ip: true,
                environment: "production".to_string(),
                prefix_tags: vec![],
            },
        ],
        global_prefix_tags: vec![],
    };

    let output = Arc::new(RecordingOutput::default());
    let collector = ServiceRadarCollector::with_output(output.clone());
    let runtime = RumRuntime::new(
        RumConfig {
            per_key_rps: 100.0,
            per_key_burst: 100.0,
            per_subnet_rps: 100.0,
            per_subnet_burst: 100.0,
            ..RumConfig::default()
        },
        Arc::new(RumPolicyCache::from_snapshot(snapshot)),
    );

    // 1. Multipart with uppercase BOUNDARY= + IPv6 literal with :8443 port
    let mut mp_headers = HeaderMap::new();
    mp_headers.insert(
        header::ORIGIN,
        HeaderValue::from_static("https://[2001:db8::1]:8443"),
    );
    mp_headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("multipart/form-data; BOUNDARY=\"MyBoundary\""),
    );
    let mp_body = b"--MyBoundary\r\nContent-Disposition: form-data; name=\"sr.key\"\r\n\r\nsr_rum_live_ipv6_port\r\n--MyBoundary\r\nContent-Disposition: form-data; name=\"u\"\r\n\r\nhttps://[2001:db8::1]:8443/checkout?page=2&token=secret\r\n--MyBoundary--\r\n";

    let resp = handle_rum_request(
        &Method::POST,
        None,
        &mp_headers,
        Full::new(Bytes::from_static(mp_body)),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // 2. Non-default port hostname preserves :8443
    let mut port_headers = HeaderMap::new();
    port_headers.insert(
        header::ORIGIN,
        HeaderValue::from_static("https://shop.example:8443"),
    );
    port_headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/x-www-form-urlencoded"),
    );
    let resp_port = handle_rum_request(
        &Method::POST,
        None,
        &port_headers,
        Full::new(Bytes::from_static(
            b"sr.key=sr_rum_live_port8443&u=https%3A%2F%2Fshop.example%3A8443%2Fcheckout%3Fpage%3D2%26token%3Dsecret",
        )),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp_port.status(), StatusCode::NO_CONTENT);

    // 3. javascript: scheme rejected with 400 Bad Request
    let resp_js = handle_rum_request(
        &Method::POST,
        None,
        &port_headers,
        Full::new(Bytes::from_static(
            b"sr.key=sr_rum_live_port8443&u=javascript%3Aalert(1)%3Ftoken%3Dabc",
        )),
        None,
        &runtime,
        &collector,
    )
    .await;
    assert_eq!(resp_js.status(), StatusCode::BAD_REQUEST);

    let beacons = output.beacons.lock().unwrap();
    assert_eq!(beacons.len(), 2);
    assert_eq!(
        beacons[0].1.url,
        "https://[2001:db8::1]:8443/checkout?page=2"
    );
    assert_eq!(beacons[0].1.host, "[2001:db8::1]");
    assert_eq!(beacons[0].1.path, "/checkout");

    assert_eq!(
        beacons[1].1.url,
        "https://shop.example:8443/checkout?page=2"
    );
    assert_eq!(beacons[1].1.host, "shop.example");
    assert_eq!(beacons[1].1.path, "/checkout");
}
