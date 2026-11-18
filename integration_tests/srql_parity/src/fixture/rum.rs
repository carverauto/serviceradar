//! Synthetic Boomerang RUM beacons (`rum_beacons`) for StarRocks-vs-CNPG parity.

use super::{Anchor, BATCH_ROWS, Backend, instant, opt_num, opt_text, text};

#[derive(Debug, Clone, PartialEq)]
pub struct RumBeaconRow {
    pub web_property_id: &'static str,
    pub observed_at: chrono::DateTime<chrono::Utc>,
    pub beacon_id: String,
    pub canonical_origin: &'static str,
    pub environment: &'static str,
    pub url: &'static str,
    pub host: &'static str,
    pub path: &'static str,
    pub metric_path: &'static str,
    pub referrer: &'static str,
    pub page_group: &'static str,
    pub initiator: &'static str,
    pub trace_id: Option<&'static str>,
    pub span_id: Option<&'static str>,
    pub session_id: &'static str,
    pub user_agent: &'static str,
    pub device_type: &'static str,
    pub browser: &'static str,
    pub os: &'static str,
    pub lcp_ms: Option<f64>,
    pub inp_ms: Option<f64>,
    pub cls: Option<f64>,
    pub fcp_ms: Option<f64>,
    pub ttfb_ms: Option<f64>,
    pub page_load_ms: Option<f64>,
    pub dns_ms: Option<f64>,
    pub connect_ms: Option<f64>,
    pub tls_ms: Option<f64>,
    pub dom_ready_ms: Option<f64>,
    pub rage_clicks: i32,
    pub js_errors: i32,
    pub http_status: i32,
    pub has_error: bool,
    pub cdn_provider: Option<&'static str>,
    pub cdn_cache_status: Option<&'static str>,
    pub cdn_edge_rtt_ms: Option<f64>,
    pub cdn_origin_rtt_ms: Option<f64>,
    pub cdn_pop: Option<&'static str>,
    pub server_timing_raw: Option<&'static str>,
    pub client_ip: &'static str,
    pub client_ip_anonymized: bool,
    pub country: Option<&'static str>,
    pub region: Option<&'static str>,
    pub city: Option<&'static str>,
    pub asn: Option<i32>,
    pub as_org: Option<&'static str>,
    pub prefix_tag: Option<&'static str>,
    pub attributes: &'static str,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

const PROP_A: &str = "01JPARITYWEBPROP0000000001";
const PROP_B: &str = "01JPARITYWEBPROP0000000002";

pub fn rows(anchor: Anchor) -> Vec<RumBeaconRow> {
    let mut rows = Vec::new();
    let paths = ["/", "/checkout", "/orders/:id"];
    let prefixes = [Some("lab-corp"), Some("partner-edge"), None];
    let countries = [Some("US"), Some("DE"), None];
    let cache_statuses = [Some("HIT"), Some("MISS"), None];

    for i in 0..24 {
        let prop = if i % 2 == 0 { PROP_A } else { PROP_B };
        let origin = if i % 2 == 0 {
            "https://shop.example"
        } else {
            "https://portal.example"
        };
        let host = if i % 2 == 0 {
            "shop.example"
        } else {
            "portal.example"
        };
        let metric_path = paths[i % paths.len()];
        let observed_at = anchor.at((i as i64) * 600 + 15);
        let lcp_ms = if i % 6 == 5 {
            None
        } else {
            Some(900.0 + (i as f64) * 75.0)
        };
        let inp_ms = if i % 4 == 3 {
            None
        } else {
            Some(30.0 + (i as f64) * 5.0)
        };
        let has_err = i % 5 == 0;

        rows.push(RumBeaconRow {
            web_property_id: prop,
            observed_at,
            beacon_id: format!("01JPARITYRUMBEACON000000{i:02}"),
            canonical_origin: origin,
            environment: if i % 2 == 0 { "production" } else { "staging" },
            url: if i % 2 == 0 {
                "https://shop.example/checkout"
            } else {
                "https://portal.example/"
            },
            host,
            path: metric_path,
            metric_path,
            referrer: "https://search.example/",
            page_group: metric_path,
            initiator: "document",
            trace_id: if i % 3 == 0 {
                Some("0123456789abcdef0123456789abcdef")
            } else {
                None
            },
            span_id: if i % 3 == 0 {
                Some("0123456789abcdef")
            } else {
                None
            },
            session_id: "sess-parity-01",
            user_agent: "Mozilla/5.0 (Example)",
            device_type: "desktop",
            browser: "ExampleBrowser",
            os: "Linux",
            lcp_ms,
            inp_ms,
            cls: Some(0.05),
            fcp_ms: Some(450.0 + (i as f64) * 10.0),
            ttfb_ms: Some(120.0 + (i as f64) * 4.0),
            page_load_ms: Some(1500.0 + (i as f64) * 40.0),
            dns_ms: Some(12.0),
            connect_ms: Some(25.0),
            tls_ms: Some(30.0),
            dom_ready_ms: Some(800.0),
            rage_clicks: if i % 7 == 0 { 2 } else { 0 },
            js_errors: if has_err { 1 } else { 0 },
            http_status: if has_err { 502 } else { 200 },
            has_error: has_err,
            cdn_provider: if cache_statuses[i % 3].is_some() {
                Some("akamai")
            } else {
                None
            },
            cdn_cache_status: cache_statuses[i % 3],
            cdn_edge_rtt_ms: if i % 3 == 2 { None } else { Some(14.5) },
            cdn_origin_rtt_ms: if i % 3 == 2 { None } else { Some(62.0) },
            cdn_pop: if i % 3 == 2 { None } else { Some("iad-01") },
            server_timing_raw: Some("cdn-cache;desc=HIT,edge;dur=14.5"),
            client_ip: if i % 2 == 0 {
                "192.0.2.0"
            } else {
                "198.51.100.0"
            },
            client_ip_anonymized: true,
            country: countries[i % 3],
            region: Some("EX"),
            city: Some("Exampleville"),
            asn: Some(64_512),
            as_org: Some("EXAMPLE-ASN"),
            prefix_tag: prefixes[i % 3],
            attributes: "{}",
            created_at: observed_at + chrono::Duration::seconds(1),
        });
    }
    rows
}

pub fn inserts(rows: &[RumBeaconRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = "web_property_id, observed_at, beacon_id, canonical_origin, environment, \
                   url, host, path, metric_path, referrer, page_group, initiator, trace_id, \
                   span_id, session_id, user_agent, device_type, browser, os, lcp_ms, inp_ms, \
                   cls, fcp_ms, ttfb_ms, page_load_ms, dns_ms, connect_ms, tls_ms, dom_ready_ms, \
                   rage_clicks, js_errors, http_status, has_error, cdn_provider, \
                   cdn_cache_status, cdn_edge_rtt_ms, cdn_origin_rtt_ms, cdn_pop, \
                   server_timing_raw, client_ip, client_ip_anonymized, country, region, city, \
                   asn, as_org, prefix_tag, attributes, created_at";
    rows.chunks(BATCH_ROWS)
        .map(|chunk| {
            let values: Vec<String> = chunk
                .iter()
                .map(|r| {
                    let attrs = match backend {
                        Backend::Cnpg => format!("{}::jsonb", text(r.attributes)),
                        Backend::StarRocks => text(r.attributes),
                    };
                    format!(
                        "({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, \
                         {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, \
                         {}, {}, {}, {}, {}, {}, {}, {}, {}, {})",
                        text(r.web_property_id),
                        instant(r.observed_at, backend),
                        text(&r.beacon_id),
                        text(r.canonical_origin),
                        text(r.environment),
                        text(r.url),
                        text(r.host),
                        text(r.path),
                        text(r.metric_path),
                        text(r.referrer),
                        text(r.page_group),
                        text(r.initiator),
                        opt_text(r.trace_id),
                        opt_text(r.span_id),
                        text(r.session_id),
                        text(r.user_agent),
                        text(r.device_type),
                        text(r.browser),
                        text(r.os),
                        opt_num(r.lcp_ms),
                        opt_num(r.inp_ms),
                        opt_num(r.cls),
                        opt_num(r.fcp_ms),
                        opt_num(r.ttfb_ms),
                        opt_num(r.page_load_ms),
                        opt_num(r.dns_ms),
                        opt_num(r.connect_ms),
                        opt_num(r.tls_ms),
                        opt_num(r.dom_ready_ms),
                        r.rage_clicks,
                        r.js_errors,
                        r.http_status,
                        if r.has_error { "TRUE" } else { "FALSE" },
                        opt_text(r.cdn_provider),
                        opt_text(r.cdn_cache_status),
                        opt_num(r.cdn_edge_rtt_ms),
                        opt_num(r.cdn_origin_rtt_ms),
                        opt_text(r.cdn_pop),
                        opt_text(r.server_timing_raw),
                        text(r.client_ip),
                        if r.client_ip_anonymized {
                            "TRUE"
                        } else {
                            "FALSE"
                        },
                        opt_text(r.country),
                        opt_text(r.region),
                        opt_text(r.city),
                        opt_num(r.asn),
                        opt_text(r.as_org),
                        opt_text(r.prefix_tag),
                        attrs,
                        instant(r.created_at, backend),
                    )
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.rum_beacons ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}
