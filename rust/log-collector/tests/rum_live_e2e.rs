//! Live end-to-end check of the public `/rum/v1/beacon` ingest gate.
//!
//! Starts a real `nats-server` with JetStream and the real `log-collector`
//! binary (embedded OTEL collector, RUM enabled), serves the RUM policy
//! snapshot over NATS request-reply the way core does, and then drives the
//! collector over TCP exactly as a browser or edge proxy would. Every
//! assertion is about what reaches the wire: HTTP status codes and the
//! `RumBeaconV1` / `MetricBatch` messages published on `rum.beacons.>` and
//! `metrics.rum.>`.
//!
//! All values are synthetic (RFC 2606 `*.example` hosts, RFC 5737 and
//! RFC 6598 addresses).

use std::fs::{self, File};
use std::io::Write as _;
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use futures::StreamExt;
use otel::rum_proto::{
    RumBeaconV1, RumPrefixTagRule, WebPropertyRumPolicy, WebPropertyRumPolicySnapshot,
};
use prost::Message;
use serviceradar_metric_proto::pb::MetricBatch;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const PROPERTY_ID: &str = "01JWEBPROPLIVE000000000001";
const SITE_KEY: &str = "sr_rum_live_e2e_storefront";
const ORIGIN: &str = "https://shop.example";
const I32_MAX: u32 = i32::MAX as u32;

struct Proc(Child);

impl Drop for Proc {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn runfile(env: &str) -> PathBuf {
    let path = std::env::var(env).unwrap_or_else(|_| panic!("{env} must be set"));
    runfiles::Runfiles::create()
        .unwrap()
        .rlocation_from(&path, "")
        .unwrap_or_else(|| panic!("runfile {path} not found"))
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

fn snapshot(version: u64, rum_enabled: bool) -> WebPropertyRumPolicySnapshot {
    WebPropertyRumPolicySnapshot {
        version,
        generated_at_unix_ms: 0,
        properties: vec![WebPropertyRumPolicy {
            web_property_id: PROPERTY_ID.to_string(),
            name: "storefront".to_string(),
            canonical_origin: ORIGIN.to_string(),
            allowed_origins: vec![ORIGIN.to_string(), "https://*.shop.example".to_string()],
            allowed_query_keys: vec!["lang".to_string()],
            trace_propagate_origins: vec![],
            rum_site_key: SITE_KEY.to_string(),
            rum_enabled,
            rum_sample_rate: 1.0,
            anonymize_client_ip: true,
            environment: "production".to_string(),
            prefix_tags: vec![RumPrefixTagRule {
                cidr: "198.51.100.0/24".to_string(),
                tag: "lab-corp".to_string(),
            }],
        }],
        global_prefix_tags: vec![],
    }
}

struct HttpReply {
    status: u16,
    head: String,
}

/// One HTTP/1.1 request over a fresh TCP connection, read to close.
async fn http(
    port: u16,
    method: &str,
    target: &str,
    headers: &[(&str, &str)],
    body: &[u8],
) -> HttpReply {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let mut req = format!(
        "{method} {target} HTTP/1.1\r\nHost: collector.example\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    );
    for (k, v) in headers {
        req.push_str(&format!("{k}: {v}\r\n"));
    }
    req.push_str("\r\n");
    stream.write_all(req.as_bytes()).await.unwrap();
    // The gate may answer and close before an oversized body is fully sent.
    let _ = stream.write_all(body).await;
    let mut raw = Vec::new();
    let _ = tokio::time::timeout(Duration::from_secs(10), stream.read_to_end(&mut raw)).await;
    let text = String::from_utf8_lossy(&raw).to_string();
    let head = text.split("\r\n\r\n").next().unwrap_or("").to_string();
    let status = head
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| panic!("no HTTP status in reply: {text:?}"));
    HttpReply { status, head }
}

fn header<'a>(reply: &'a HttpReply, name: &str) -> Option<&'a str> {
    reply.head.lines().find_map(|line| {
        let (k, v) = line.split_once(':')?;
        k.trim().eq_ignore_ascii_case(name).then(|| v.trim())
    })
}

async fn beacon(port: u16, extra: &[(&str, &str)], content_type: &str, body: &[u8]) -> HttpReply {
    let mut headers = vec![("Origin", ORIGIN), ("Content-Type", content_type)];
    headers.extend_from_slice(extra);
    http(
        port,
        "POST",
        &format!("/rum/v1/beacon?key={SITE_KEY}"),
        &headers,
        body,
    )
    .await
}

async fn next_beacon(sub: &mut async_nats::Subscriber) -> (String, RumBeaconV1) {
    let msg = tokio::time::timeout(Duration::from_secs(10), sub.next())
        .await
        .expect("no rum.beacons message within 10s")
        .unwrap();
    (
        msg.subject.to_string(),
        RumBeaconV1::decode(msg.payload.as_ref()).unwrap(),
    )
}

async fn next_metrics(sub: &mut async_nats::Subscriber) -> (String, MetricBatch) {
    let msg = tokio::time::timeout(Duration::from_secs(10), sub.next())
        .await
        .expect("no metrics.rum message within 10s")
        .unwrap();
    (
        msg.subject.to_string(),
        MetricBatch::decode(msg.payload.as_ref()).unwrap(),
    )
}

async fn drain(sub: &mut async_nats::Subscriber) {
    while tokio::time::timeout(Duration::from_millis(500), sub.next())
        .await
        .is_ok()
    {}
}

fn all_strings(b: &RumBeaconV1) -> Vec<(&'static str, &str)> {
    vec![
        ("beacon_id", &b.beacon_id),
        ("url", &b.url),
        ("host", &b.host),
        ("path", &b.path),
        ("metric_path", &b.metric_path),
        ("referrer", &b.referrer),
        ("page_group", &b.page_group),
        ("initiator", &b.initiator),
        ("session_id", &b.session_id),
        ("user_agent", &b.user_agent),
        ("device_type", &b.device_type),
        ("cdn_provider", &b.cdn_provider),
        ("cdn_cache_status", &b.cdn_cache_status),
        ("cdn_pop", &b.cdn_pop),
        ("server_timing_raw", &b.server_timing_raw),
        ("country", &b.country),
        ("region", &b.region),
        ("city", &b.city),
        ("as_org", &b.as_org),
        ("prefix_tag", &b.prefix_tag),
    ]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rum_beacon_gate_against_real_collector_and_nats() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let nats_port = free_port();
    let grpc_port = free_port();
    let http_port = free_port();
    let health_port = free_port();

    let _nats = Proc(
        Command::new(runfile("NATS_SERVER_BIN"))
            .args([
                "-a",
                "127.0.0.1",
                "-p",
                &nats_port.to_string(),
                "-js",
                "-sd",
            ])
            .arg(root.join("js"))
            .stdout(File::create(root.join("nats.out")).unwrap())
            .stderr(File::create(root.join("nats.err")).unwrap())
            .spawn()
            .unwrap(),
    );
    let nats_url = format!("nats://127.0.0.1:{nats_port}");
    let deadline = Instant::now() + Duration::from_secs(15);
    let client = loop {
        if let Ok(c) = async_nats::connect(&nats_url).await {
            break c;
        }
        assert!(Instant::now() < deadline, "nats-server never came up");
        tokio::time::sleep(Duration::from_millis(100)).await;
    };

    // Core's RumPolicySync responder, served from a synthetic snapshot.
    let mut policy_requests = client
        .subscribe("config.rum.policy.snapshot")
        .await
        .unwrap();
    let responder = client.clone();
    tokio::spawn(async move {
        while let Some(req) = policy_requests.next().await {
            if let Some(reply) = req.reply {
                let _ = responder
                    .publish(reply, snapshot(10, true).encode_to_vec().into())
                    .await;
            }
        }
    });
    // EventWriter owns the `metrics` stream (subject `metrics.>`) in a
    // deployment; create it the same way so `metrics.rum.*` publishes are acked.
    async_nats::jetstream::new(client.clone())
        .create_stream(async_nats::jetstream::stream::Config {
            name: "metrics".to_string(),
            subjects: vec!["metrics.>".to_string()],
            ..Default::default()
        })
        .await
        .unwrap();
    let mut beacons = client.subscribe("rum.beacons.>").await.unwrap();
    let mut metrics = client.subscribe("metrics.rum.>").await.unwrap();
    client.flush().await.unwrap();

    fs::write(
        root.join("otel.toml"),
        format!(
            r#"[server]
bind_address = "127.0.0.1"
port = {grpc_port}
[server.http]
enabled = true
bind_address = "127.0.0.1"
port = {http_port}
[nats]
url = "{nats_url}"
stream = "events"
timeout_secs = 5
[rum]
enabled = true
per_subnet_rps = 0.01
per_subnet_burst = 3
"#
        ),
    )
    .unwrap();
    fs::write(
        root.join("collector.toml"),
        format!(
            "[flowgger]\nenabled = false\n[otel]\nenabled = true\nconfig_file = {:?}\n[health]\nlisten_addr = \"127.0.0.1:{health_port}\"\n",
            root.join("otel.toml")
        ),
    )
    .unwrap();
    let mut collector = Proc(
        Command::new(runfile("LOG_COLLECTOR_BIN"))
            .arg("--config")
            .arg(root.join("collector.toml"))
            .env_remove("PINNED_CONFIG_PATH")
            .env("RUST_LOG", "info")
            .stdin(Stdio::null())
            .stdout(File::create(root.join("collector.out")).unwrap())
            .stderr(File::create(root.join("collector.err")).unwrap())
            .spawn()
            .unwrap(),
    );
    let logs = || fs::read_to_string(root.join("collector.err")).unwrap_or_default();

    // Ready once the policy snapshot is applied: preflight for the key is allowed.
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        assert!(
            collector.0.try_wait().unwrap().is_none(),
            "collector exited: {}",
            logs()
        );
        if TcpStream::connect(("127.0.0.1", http_port)).await.is_ok() {
            let pre = http(
                http_port,
                "OPTIONS",
                &format!("/rum/v1/beacon?key={SITE_KEY}"),
                &[
                    ("Origin", ORIGIN),
                    ("Access-Control-Request-Method", "POST"),
                ],
                b"",
            )
            .await;
            if pre.status == 204 {
                println!(
                    "[preflight] OPTIONS allowed origin -> 204, allow-origin={:?}",
                    header(&pre, "access-control-allow-origin")
                );
                assert_eq!(header(&pre, "access-control-allow-origin"), Some(ORIGIN));
                break;
            }
        }
        assert!(
            Instant::now() < deadline,
            "RUM policy never applied: {}",
            logs()
        );
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    // --- Scenario: accepted beacon is scrubbed, enriched, and published ---
    let body = format!(
        r#"{{"u":"https://us.shop.example/orders/987654?token=secret&lang=en#frag","r":"https://ref.example/login?code=abc","c.lcp":1420.5,"c.inp":48.0,"c.cls":0.04,"servertiming":"cdn-cache;desc=HIT,edge;dur=12.4,origin;dur=55.2,ak_p;desc=iad-01","sr.trace_id":"0123456789abcdef0123456789abcdef","sr.span_id":"0123456789abcdef","rt.tstart":{}}}"#,
        now_ms() - 1_000
    );
    let ok = beacon(
        http_port,
        &[
            ("True-Client-IP", "198.51.100.77"),
            (
                "Akamai-Edgescape",
                "country_code=US,region_code=CA,city=SANJOSE,asnum=64512,network=EXAMPLENET",
            ),
        ],
        "application/json",
        body.as_bytes(),
    )
    .await;
    println!("[accept] POST valid key/origin -> {}", ok.status);
    assert_eq!(ok.status, 204, "{}", logs());
    let (subject, b) = next_beacon(&mut beacons).await;
    println!(
        "[accept] {subject}: url={} referrer={} metric_path={} client_ip={} anonymized={} prefix_tag={} country={} asn={} as_org={} cdn_cache={} edge_rtt={:?} origin_rtt={:?} pop={} lcp={:?} trace_id={}",
        b.url,
        b.referrer,
        b.metric_path,
        b.client_ip,
        b.client_ip_anonymized,
        b.prefix_tag,
        b.country,
        b.asn,
        b.as_org,
        b.cdn_cache_status,
        b.cdn_edge_rtt_ms,
        b.cdn_origin_rtt_ms,
        b.cdn_pop,
        b.lcp_ms,
        b.trace_id
    );
    assert_eq!(subject, format!("rum.beacons.{PROPERTY_ID}"));
    assert_eq!(b.web_property_id, PROPERTY_ID);
    assert_eq!(b.url, "https://us.shop.example/orders/987654?lang=en");
    assert_eq!(b.referrer, "https://ref.example/login");
    assert_eq!(b.metric_path, "/orders/:id");
    assert_eq!(b.client_ip, "198.51.100.0");
    assert!(b.client_ip_anonymized);
    assert_eq!(b.prefix_tag, "lab-corp");
    assert_eq!(b.country, "US");
    assert_eq!(b.asn, 64512);
    assert_eq!(b.cdn_cache_status, "HIT");
    assert_eq!(b.cdn_edge_rtt_ms, Some(12.4));
    assert_eq!(b.cdn_origin_rtt_ms, Some(55.2));
    assert_eq!(b.cdn_pop, "iad-01");
    assert_eq!(b.lcp_ms, Some(1420.5));
    let (msubject, batch) = next_metrics(&mut metrics).await;
    let names: Vec<_> = batch.metrics.iter().map(|m| m.name.as_str()).collect();
    println!("[accept] {msubject}: metrics={names:?}");
    assert_eq!(msubject, format!("metrics.rum.{PROPERTY_ID}"));
    assert!(names.contains(&"rum.lcp_ms"));
    assert!(names.contains(&"rum.akamai_edge_rtt_ms"));

    // --- Scenario: the gate rejects what it must ---
    let cases: Vec<(&str, HttpReply, u16)> = vec![
        (
            "missing key",
            http(
                http_port,
                "POST",
                "/rum/v1/beacon",
                &[("Origin", ORIGIN), ("True-Client-IP", "100.64.1.1")],
                b"u=x",
            )
            .await,
            401,
        ),
        (
            "unknown key",
            http(
                http_port,
                "POST",
                "/rum/v1/beacon?key=sr_rum_nope",
                &[("Origin", ORIGIN), ("True-Client-IP", "100.64.2.1")],
                b"u=x",
            )
            .await,
            401,
        ),
        (
            "GET",
            http(
                http_port,
                "GET",
                &format!("/rum/v1/beacon?key={SITE_KEY}"),
                &[("Origin", ORIGIN)],
                b"",
            )
            .await,
            405,
        ),
        (
            "oversized 70 KiB body",
            beacon(
                http_port,
                &[("True-Client-IP", "100.64.5.1")],
                "application/x-www-form-urlencoded",
                &vec![b'a'; 70 * 1024],
            )
            .await,
            413,
        ),
    ];
    for (name, reply, want) in &cases {
        println!("[reject] {name} -> {}", reply.status);
        assert_eq!(reply.status, *want, "{name}");
    }
    let evil = http(
        http_port,
        "POST",
        &format!("/rum/v1/beacon?key={SITE_KEY}"),
        &[
            ("Origin", "https://evil.example"),
            ("True-Client-IP", "100.64.3.1"),
        ],
        b"u=https%3A%2F%2Fshop.example%2F",
    )
    .await;
    println!("[reject] disallowed origin -> {}", evil.status);
    assert_eq!(evil.status, 403);
    let pre_evil = http(
        http_port,
        "OPTIONS",
        &format!("/rum/v1/beacon?key={SITE_KEY}"),
        &[("Origin", "https://evil.example")],
        b"",
    )
    .await;
    println!(
        "[reject] preflight disallowed origin -> {}",
        pre_evil.status
    );
    assert_eq!(pre_evil.status, 403);

    let mut bomb = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
    bomb.write_all(&vec![b'a'; 1024 * 1024]).unwrap();
    let bomb = bomb.finish().unwrap();
    let gz = beacon(
        http_port,
        &[
            ("Content-Encoding", "gzip"),
            ("True-Client-IP", "100.64.6.1"),
        ],
        "application/x-www-form-urlencoded",
        &bomb,
    )
    .await;
    println!(
        "[reject] gzip bomb ({} B wire -> 1 MiB) -> {}",
        bomb.len(),
        gz.status
    );
    assert_eq!(gz.status, 413);

    let mut statuses = Vec::new();
    for _ in 0..5 {
        let r = beacon(
            http_port,
            &[("True-Client-IP", "100.64.7.9")],
            "application/x-www-form-urlencoded",
            b"u=https%3A%2F%2Fshop.example%2F",
        )
        .await;
        statuses.push((r.status, header(&r, "retry-after").map(str::to_owned)));
    }
    println!("[reject] 5 beacons from one /24 (burst 3) -> {statuses:?}");
    assert!(statuses.iter().take(3).all(|(s, _)| *s == 204));
    assert!(
        statuses
            .iter()
            .skip(3)
            .all(|(s, ra)| *s == 429 && ra.is_some())
    );
    for _ in 0..3 {
        next_beacon(&mut beacons).await;
    }
    drain(&mut metrics).await;

    // --- Scenario: hostile values are bounded before publish ---
    let far_future = now_ms() + 10 * 365 * 24 * 3_600_000;
    let long_id = "b".repeat(300);
    let long_dev = "d".repeat(500);
    let nul_url = beacon(
        http_port,
        &[("True-Client-IP", "203.0.112.9")],
        "application/x-www-form-urlencoded",
        b"u=https%3A%2F%2Fshop.example%2Fa%00b",
    )
    .await;
    println!("[hostile] page URL containing NUL -> {}", nul_url.status);
    assert_eq!(nul_url.status, 400);
    let hostile = format!(
        "u=https%3A%2F%2Fshop.example%2Fcart&sr.initiator=xh%00r&pgu=https%3A%2F%2Fshop.example%2Fgr%00oup&rt.tstart={far_future}&sr.beacon_id={long_id}&c.e.rage=3000000000&js_errors=3000000000&http.status_code=3000000000&rt.si=se%00ss&mob.etype={long_dev}&c.lcp=900"
    );
    let h = beacon(
        http_port,
        &[
            ("True-Client-IP", "203.0.113.9"),
            (
                "Akamai-Edgescape",
                "country_code=U%00S,asnum=4200000000,network=PRIV",
            ),
        ],
        "application/x-www-form-urlencoded",
        hostile.as_bytes(),
    )
    .await;
    println!("[hostile] POST hostile beacon -> {}", h.status);
    assert_eq!(h.status, 204, "{}", logs());
    let (_, hb) = next_beacon(&mut beacons).await;
    let skew = (hb.observed_at_unix_ms - now_ms()).abs();
    println!(
        "[hostile] observed_at skew={skew}ms rage={} js_errors={} http_status={} asn={} beacon_id_len={} device_type_len={} session_id={:?} initiator={:?} page_group={:?}",
        hb.rage_clicks,
        hb.js_errors,
        hb.http_status,
        hb.asn,
        hb.beacon_id.len(),
        hb.device_type.len(),
        hb.session_id,
        hb.initiator,
        hb.page_group
    );
    assert!(
        skew < 120_000,
        "far-future timestamp must fall back to server time"
    );
    assert!(hb.rage_clicks <= I32_MAX && hb.js_errors <= I32_MAX && hb.http_status <= I32_MAX);
    assert_eq!(hb.asn, 0, "ASN above signed INT must be dropped");
    assert!(hb.beacon_id.len() <= 64);
    assert!(hb.device_type.len() <= 64);
    for (field, value) in all_strings(&hb) {
        assert!(
            !value.contains('\0'),
            "{field} still carries NUL: {value:?}"
        );
    }
    let (_, hm) = next_metrics(&mut metrics).await;
    for m in &hm.metrics {
        for p in &m.points {
            let point_skew = (p.observed_at_unix_nano as i64 / 1_000_000 - now_ms()).abs();
            assert!(
                point_skew < 120_000,
                "metric {} carries client timestamp",
                m.name
            );
        }
    }
    println!(
        "[hostile] {} metric points all stamped within 120s of server time",
        hm.metrics.len()
    );

    // --- Scenario: stalled RUM uploads cannot starve OTLP ingest ---
    let mut stalled = Vec::new();
    for i in 0..24u8 {
        let mut s = TcpStream::connect(("127.0.0.1", http_port)).await.unwrap();
        let head = format!(
            "POST /rum/v1/beacon?key={SITE_KEY} HTTP/1.1\r\nHost: collector.example\r\nOrigin: {ORIGIN}\r\nTrue-Client-IP: 100.65.{i}.1\r\nContent-Type: text/plain\r\nContent-Length: 4000\r\n\r\nu=",
        );
        s.write_all(head.as_bytes()).await.unwrap();
        stalled.push(s);
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    let started = Instant::now();
    let otlp = http(
        http_port,
        "POST",
        "/v1/traces",
        &[("Content-Type", "application/x-protobuf")],
        b"",
    )
    .await;
    println!(
        "[isolation] 24 stalled RUM uploads held open; OTLP POST /v1/traces -> {} in {:?}",
        otlp.status,
        started.elapsed()
    );
    assert_eq!(
        otlp.status, 200,
        "OTLP must keep its own request budget: {}",
        otlp.head
    );
    drop(stalled);

    // --- Scenario: a policy update over NATS disables the key live ---
    client
        .publish(
            "config.rum.policy.updates",
            snapshot(11, false).encode_to_vec().into(),
        )
        .await
        .unwrap();
    client.flush().await.unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let disabled = loop {
        let r = beacon(
            http_port,
            &[("True-Client-IP", "100.66.0.1")],
            "text/plain",
            b"u=https%3A%2F%2Fshop.example%2F",
        )
        .await;
        if r.status != 204 {
            break r;
        }
        next_beacon(&mut beacons).await;
        assert!(Instant::now() < deadline, "policy update never applied");
        tokio::time::sleep(Duration::from_millis(200)).await;
    };
    println!(
        "[policy] after update rum_enabled=false -> {}",
        disabled.status
    );
    assert_eq!(disabled.status, 403);
    assert!(
        tokio::time::timeout(Duration::from_millis(500), beacons.next())
            .await
            .is_err(),
        "a rejected beacon must not be published"
    );

    // JetStream stream captured the RUM subjects (durable, not only core pub/sub).
    let js = async_nats::jetstream::new(client.clone());
    let mut stream = js.get_stream("events").await.unwrap();
    let info = stream.info().await.unwrap();
    println!(
        "[jetstream] stream events subjects={:?} messages={}",
        info.config.subjects, info.state.messages
    );
    assert!(info.config.subjects.iter().any(|s| s == "rum.beacons.>"));
    assert!(info.state.messages >= 6);
}
