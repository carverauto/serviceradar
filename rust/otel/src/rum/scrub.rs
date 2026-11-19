use std::collections::HashMap;
use std::net::IpAddr;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use hyper::header::{HeaderMap, USER_AGENT};
use serviceradar_metric_proto::pb::{
    IngestIdentity, Metric, MetricBatch, MetricKind, MetricPoint, MetricResource, MetricValueType,
    StringMapEntry,
};
use uuid::Uuid;

use crate::output::METRIC_ENVELOPE_SCHEMA_VERSION;
use crate::rum::policy::{CompiledPropertyPolicy, RumPolicyCache};
use crate::rum::prefix::{Prefix, ip_in_cidrs, truncate_ip};
use crate::rum_proto::RumBeaconV1;

const MAX_SERVER_TIMING_RAW_BYTES: usize = 512;
const MAX_OBSERVED_AT_PAST_MS: i64 = 7 * 24 * 60 * 60 * 1000;
const MAX_OBSERVED_AT_FUTURE_MS: i64 = 5 * 60 * 1000;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GeoAsnInfo {
    pub country: String,
    pub region: String,
    pub city: String,
    pub asn: u32,
    pub as_org: String,
}

#[derive(Debug, Default)]
pub struct StaticGeoAsn {
    entries: Vec<(Prefix, GeoAsnInfo)>,
}

impl StaticGeoAsn {
    pub fn from_file(path: &Path) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let mut entries = Vec::new();
        if let Ok(json_entries) = serde_json::from_str::<Vec<serde_json::Value>>(&content) {
            for item in json_entries {
                if let Some(cidr) = item.get("cidr").and_then(|v| v.as_str())
                    && let Some(prefix) = Prefix::parse(cidr)
                {
                    entries.push((
                        prefix,
                        GeoAsnInfo {
                            country: item
                                .get("country")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string(),
                            region: item
                                .get("region")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string(),
                            city: item
                                .get("city")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string(),
                            asn: item.get("asn").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
                            as_org: item
                                .get("as_org")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string(),
                        },
                    ));
                }
            }
        }
        Ok(Self { entries })
    }

    pub fn lookup(&self, ip: IpAddr) -> Option<&GeoAsnInfo> {
        self.entries
            .iter()
            .filter(|(prefix, _)| prefix.contains_ip(ip))
            .max_by_key(|(prefix, _)| prefix.length)
            .map(|(_, info)| info)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScrubbedUrl {
    pub url: String,
    pub host: String,
    pub path: String,
}

/// Decodes a Boomerang payload from `application/x-www-form-urlencoded`,
/// `application/json`, `text/plain`, or `multipart/form-data`.
pub fn decode_beacon_params(
    content_type: &str,
    body: &[u8],
) -> Result<HashMap<String, String>, String> {
    let media_type = content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();

    match media_type.as_str() {
        "" | "application/x-www-form-urlencoded" => {
            let text = std::str::from_utf8(body).map_err(|_| "invalid UTF-8 beacon body")?;
            Ok(parse_form_urlencoded(text))
        }
        "application/json" => {
            let text = std::str::from_utf8(body).map_err(|_| "invalid UTF-8 JSON beacon")?;
            parse_json_params(text)
        }
        "text/plain" => {
            let text = std::str::from_utf8(body).map_err(|_| "invalid UTF-8 text beacon")?;
            let trimmed = text.trim();
            if trimmed.starts_with('{') {
                parse_json_params(trimmed)
            } else {
                Ok(parse_form_urlencoded(trimmed))
            }
        }
        "multipart/form-data" => {
            let boundary = extract_multipart_boundary(content_type)
                .ok_or_else(|| "multipart/form-data missing boundary".to_string())?;
            parse_multipart_form(body, &boundary)
        }
        other => Err(format!("unsupported RUM content-type '{other}'")),
    }
}

pub fn parse_form_urlencoded(input: &str) -> HashMap<String, String> {
    let mut params = HashMap::new();
    let trimmed = input.trim().trim_start_matches('?');
    if trimmed.is_empty() {
        return params;
    }
    for pair in trimmed.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (raw_k, raw_v) = match pair.split_once('=') {
            Some((k, v)) => (k, v),
            None => (pair, ""),
        };
        let k_plus = raw_k.replace('+', " ");
        let v_plus = raw_v.replace('+', " ");
        if let (Ok(k), Ok(v)) = (urlencoding::decode(&k_plus), urlencoding::decode(&v_plus)) {
            let key = k.trim().to_string();
            if !key.is_empty() {
                params.insert(key, v.into_owned());
            }
        }
    }
    params
}

fn parse_json_params(text: &str) -> Result<HashMap<String, String>, String> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|e| format!("invalid JSON beacon: {e}"))?;
    let obj = value
        .as_object()
        .ok_or_else(|| "JSON beacon must be an object".to_string())?;
    let mut out = HashMap::with_capacity(obj.len());
    for (k, v) in obj {
        let rendered = match v {
            serde_json::Value::Null => continue,
            serde_json::Value::String(s) => s.clone(),
            serde_json::Value::Number(n) => n.to_string(),
            serde_json::Value::Bool(b) => b.to_string(),
            other => other.to_string(),
        };
        out.insert(k.clone(), rendered);
    }
    Ok(out)
}

fn extract_multipart_boundary(content_type: &str) -> Option<String> {
    for param in content_type.split(';').skip(1) {
        let trimmed = param.trim();
        if let Some((name, raw)) = trimmed.split_once('=')
            && name.trim().eq_ignore_ascii_case("boundary")
        {
            let boundary = raw.trim().trim_matches('"');
            if !boundary.is_empty() {
                return Some(boundary.to_string());
            }
        }
    }
    None
}

fn parse_multipart_form(body: &[u8], boundary: &str) -> Result<HashMap<String, String>, String> {
    let text = std::str::from_utf8(body).map_err(|_| "invalid UTF-8 multipart beacon")?;
    let delimiter = format!("--{boundary}");
    let mut out = HashMap::new();
    for part in text.split(&delimiter) {
        let part = part.trim_start_matches("\r\n").trim_start_matches('\n');
        if part.is_empty() || part.starts_with("--") {
            continue;
        }
        let (headers_section, value_section) = match part.split_once("\r\n\r\n") {
            Some((h, v)) => (h, v.trim_end_matches("\r\n")),
            None => match part.split_once("\n\n") {
                Some((h, v)) => (h, v.trim_end_matches('\n')),
                None => continue,
            },
        };
        if let Some(name) = extract_part_name(headers_section) {
            out.insert(name, value_section.to_string());
        }
    }
    Ok(out)
}

fn extract_part_name(headers: &str) -> Option<String> {
    for line in headers.lines() {
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("content-disposition:")
            && let Some(idx) = lower.find("name=\"")
        {
            let rest = &line[idx + 6..];
            if let Some(end) = rest.find('"') {
                return Some(rest[..end].to_string());
            }
        }
    }
    None
}

/// Strips `#fragment` and `?query` from `raw`, keeping ONLY exact keys present in
/// `allowed_query_keys`. Returns scrubbed URL, host, and path.
pub fn scrub_url(raw: &str, allowed_query_keys: &[String]) -> Option<ScrubbedUrl> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.bytes().any(|b| b.is_ascii_control()) {
        return None;
    }
    let without_fragment = trimmed.split('#').next().unwrap_or(trimmed);
    let (base, raw_query) = match without_fragment.split_once('?') {
        Some((b, q)) => (b, Some(q)),
        None => (without_fragment, None),
    };
    if base.starts_with("//") {
        return None;
    }

    let is_explicit_relative =
        base.starts_with('/') || base.starts_with("./") || base.starts_with("../");
    let (scheme, host, port, path) =
        if !is_explicit_relative && let Some((raw_scheme, rest)) = base.split_once("://") {
            let scheme = raw_scheme.to_ascii_lowercase();
            if scheme != "http" && scheme != "https" {
                return None;
            }
            let (authority, raw_path) = match rest.find('/') {
                Some(idx) => (&rest[..idx], &rest[idx..]),
                None => (rest, "/"),
            };
            let host_port = authority.rsplit('@').next().unwrap_or(authority).trim();
            let (parsed_host, parsed_port) = split_scrub_host_port(host_port)?;
            let host = parsed_host.to_ascii_lowercase();
            if host.is_empty() {
                return None;
            }
            let default_port = if scheme == "https" { 443 } else { 80 };
            let port = parsed_port.filter(|&p| p != default_port);
            let path = normalize_raw_path(raw_path);
            (
                Some(scheme),
                host,
                port,
                if path.is_empty() {
                    "/".to_string()
                } else {
                    path
                },
            )
        } else {
            if has_explicit_scheme_prefix(base) {
                return None;
            }
            let path = normalize_raw_path(base);
            (None, String::new(), None, path)
        };

    let retained_query = if let (Some(q), false) = (raw_query, allowed_query_keys.is_empty()) {
        let kept: Vec<String> = q
            .split('&')
            .filter_map(|pair| {
                let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
                let decoded_k = urlencoding::decode(k).ok()?;
                if allowed_query_keys
                    .iter()
                    .any(|allow| allow == decoded_k.as_ref())
                {
                    Some(if v.is_empty() {
                        k.to_string()
                    } else {
                        format!("{k}={v}")
                    })
                } else {
                    None
                }
            })
            .collect();
        if kept.is_empty() {
            None
        } else {
            Some(kept.join("&"))
        }
    } else {
        None
    };

    let scrubbed_base = match scheme {
        Some(s) => match port {
            Some(p) => format!("{s}://{host}:{p}{path}"),
            None => format!("{s}://{host}{path}"),
        },
        None => path.clone(),
    };
    let url = match retained_query {
        Some(q) => format!("{scrubbed_base}?{q}"),
        None => scrubbed_base,
    };

    Some(ScrubbedUrl { url, host, path })
}

fn split_scrub_host_port(authority: &str) -> Option<(&str, Option<u16>)> {
    if authority.starts_with('[') {
        let end = authority.find(']')?;
        let host = &authority[..=end];
        if host.len() <= 2 {
            return None;
        }
        let after = &authority[end + 1..];
        if after.is_empty() {
            return Some((host, None));
        }
        let port_str = after.strip_prefix(':')?;
        if port_str.is_empty() {
            return Some((host, None));
        }
        let port = port_str.parse::<u16>().ok()?;
        return Some((host, Some(port)));
    }
    match authority.rsplit_once(':') {
        Some((host, port_str)) if !host.contains(':') => {
            if port_str.is_empty() {
                Some((host, None))
            } else {
                let port = port_str.parse::<u16>().ok()?;
                Some((host, Some(port)))
            }
        }
        Some(_) => None,
        None => Some((authority, None)),
    }
}

fn has_explicit_scheme_prefix(base: &str) -> bool {
    if base.starts_with('/') || base.starts_with("./") || base.starts_with("../") {
        return false;
    }
    let first_seg = base.split('/').next().unwrap_or(base);
    let Some((scheme, _)) = first_seg.split_once(':') else {
        return false;
    };
    let mut bytes = scheme.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    first.is_ascii_alphabetic()
        && bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
}

fn normalize_raw_path(raw: &str) -> String {
    if raw.is_empty() {
        "/".to_string()
    } else if raw.starts_with('/') {
        raw.to_string()
    } else {
        format!("/{raw}")
    }
}

/// Collapses dynamic path segments (UUIDs, long hex tokens, numeric IDs) into `/:id`
/// to keep `metrics.rum.>` tag cardinality bounded.
pub fn normalize_metric_path(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() || trimmed == "/" {
        return "/".to_string();
    }
    let normalized: Vec<&str> = trimmed
        .split('/')
        .filter(|seg| !seg.is_empty())
        .map(|seg| if is_dynamic_segment(seg) { ":id" } else { seg })
        .collect();
    if normalized.is_empty() {
        "/".to_string()
    } else {
        format!("/{}", normalized.join("/"))
    }
}

fn is_dynamic_segment(seg: &str) -> bool {
    if seg.bytes().all(|b| b.is_ascii_digit()) {
        return true;
    }
    if Uuid::parse_str(seg).is_ok() {
        return true;
    }
    seg.len() >= 16 && seg.bytes().all(|b| b.is_ascii_hexdigit())
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ServerTimingMetrics {
    pub cdn_provider: String,
    pub cdn_cache_status: String,
    pub cdn_edge_rtt_ms: Option<f64>,
    pub cdn_origin_rtt_ms: Option<f64>,
    pub cdn_pop: String,
}

/// Parses W3C `Server-Timing` entries (from Boomerang `servertiming`/`st` or HTTP header).
pub fn parse_server_timing(raw: &str) -> ServerTimingMetrics {
    let mut out = ServerTimingMetrics::default();
    for entry in raw.split(',') {
        let mut parts = entry.split(';').map(str::trim);
        let Some(metric_name) = parts.next() else {
            continue;
        };
        let name = metric_name.to_ascii_lowercase();
        let mut dur: Option<f64> = None;
        let mut desc: Option<String> = None;
        for param in parts {
            if let Some((k, v)) = param.split_once('=') {
                let key = k.trim().to_ascii_lowercase();
                let val = v.trim().trim_matches('"');
                match key.as_str() {
                    "dur" => {
                        dur = val
                            .parse::<f64>()
                            .ok()
                            .filter(|n| n.is_finite() && *n >= 0.0)
                    }
                    "desc" => desc = Some(val.to_string()),
                    _ => {}
                }
            }
        }

        match name.as_str() {
            "cdn-cache" => {
                if let Some(d) = desc {
                    out.cdn_cache_status = d.to_ascii_uppercase();
                }
            }
            "edge" => {
                if let Some(ms) = dur {
                    out.cdn_edge_rtt_ms = Some(ms);
                }
            }
            "origin" => {
                if let Some(ms) = dur {
                    out.cdn_origin_rtt_ms = Some(ms);
                }
            }
            "ak_p" => {
                out.cdn_provider = "akamai".to_string();
                if let Some(d) = desc {
                    out.cdn_pop = d;
                }
            }
            "cdn-pop" => {
                if let Some(d) = desc {
                    out.cdn_pop = d;
                }
            }
            _ => {}
        }
    }
    if out.cdn_provider.is_empty()
        && (!out.cdn_cache_status.is_empty()
            || out.cdn_edge_rtt_ms.is_some()
            || out.cdn_origin_rtt_ms.is_some())
    {
        out.cdn_provider = "akamai".to_string();
    }
    out
}

pub fn parse_akamai_edgescape(raw: &str) -> GeoAsnInfo {
    let mut info = GeoAsnInfo::default();
    for pair in raw.split(',') {
        let Some((k, v)) = pair.split_once('=') else {
            continue;
        };
        let key = k.trim().to_ascii_lowercase();
        let val = v.trim();
        match key.as_str() {
            "country_code" => info.country = val.to_ascii_uppercase(),
            "region_code" => info.region = val.to_ascii_uppercase(),
            "city" => info.city = val.to_string(),
            "asnum" => {
                if let Ok(asn) = val.parse::<u32>() {
                    info.asn = asn;
                }
            }
            "network" => info.as_org = val.to_string(),
            _ => {}
        }
    }
    info
}

pub fn resolve_client_ip(
    peer_ip: Option<IpAddr>,
    headers: &HeaderMap,
    trusted_proxies: &[Prefix],
) -> (Option<IpAddr>, bool) {
    let Some(peer) = peer_ip else {
        return (None, false);
    };
    let trusted = ip_in_cidrs(peer, trusted_proxies);
    if !trusted {
        return (Some(peer), false);
    }

    if let Some(true_client) = headers
        .get("true-client-ip")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<IpAddr>().ok())
    {
        return (Some(true_client), true);
    }

    if let Some(xff) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
        let parsed: Vec<IpAddr> = xff
            .split(',')
            .filter_map(|part| part.trim().parse::<IpAddr>().ok())
            .collect();
        if let Some(client) = parsed
            .iter()
            .rev()
            .find(|ip| !ip_in_cidrs(**ip, trusted_proxies))
            .or_else(|| parsed.first())
        {
            return (Some(*client), true);
        }
    }

    (Some(peer), true)
}

pub fn validate_hex_id(raw: Option<&str>, expected_len: usize) -> String {
    let Some(val) = raw.map(str::trim) else {
        return String::new();
    };
    if val.len() == expected_len
        && val.bytes().all(|b| b.is_ascii_hexdigit())
        && val.bytes().any(|b| b != b'0')
    {
        val.to_ascii_lowercase()
    } else {
        String::new()
    }
}

pub fn build_beacon_and_metrics(
    params: &HashMap<String, String>,
    headers: &HeaderMap,
    peer_ip: Option<IpAddr>,
    trusted_proxies: &[Prefix],
    policy: &CompiledPropertyPolicy,
    policy_cache: &RumPolicyCache,
    static_geo: Option<&StaticGeoAsn>,
) -> Result<(RumBeaconV1, Option<MetricBatch>), String> {
    let raw_u = params
        .get("u")
        .or_else(|| params.get("url"))
        .map(String::as_str)
        .unwrap_or("");
    let scrubbed_u = scrub_url(raw_u, &policy.allowed_query_keys)
        .ok_or_else(|| "beacon missing required 'u' page URL".to_string())?;

    let scrubbed_r = params
        .get("r")
        .or_else(|| params.get("referrer"))
        .and_then(|r| scrub_url(r, &policy.allowed_query_keys))
        .map(|s| s.url)
        .unwrap_or_default();

    let scrubbed_pgu = params
        .get("pgu")
        .and_then(|p| scrub_url(p, &policy.allowed_query_keys));
    let page_group = scrubbed_pgu
        .as_ref()
        .map(|s| s.path.clone())
        .unwrap_or_default();
    let metric_path = normalize_metric_path(
        scrubbed_pgu
            .as_ref()
            .map(|s| s.path.as_str())
            .unwrap_or(scrubbed_u.path.as_str()),
    );

    let raw_server_timing = params
        .get("servertiming")
        .or_else(|| params.get("st"))
        .map(String::as_str)
        .or_else(|| headers.get("server-timing").and_then(|v| v.to_str().ok()))
        .unwrap_or("")
        .trim();
    let server_timing_bounded: String = raw_server_timing
        .chars()
        .take(MAX_SERVER_TIMING_RAW_BYTES)
        .collect();
    let st = parse_server_timing(&server_timing_bounded);

    let (client_ip_raw, from_trusted_proxy) = resolve_client_ip(peer_ip, headers, trusted_proxies);

    let mut geo = if from_trusted_proxy {
        headers
            .get("akamai-edgescape")
            .and_then(|v| v.to_str().ok())
            .map(parse_akamai_edgescape)
            .unwrap_or_default()
    } else {
        GeoAsnInfo::default()
    };

    let prefix_tag = client_ip_raw
        .and_then(|ip| policy_cache.lookup_prefix_tag(policy, ip))
        .unwrap_or_default();

    if let (Some(ip), Some(geo_db)) = (client_ip_raw, static_geo)
        && let Some(found) = geo_db.lookup(ip)
    {
        if geo.country.is_empty() {
            geo.country = found.country.clone();
        }
        if geo.region.is_empty() {
            geo.region = found.region.clone();
        }
        if geo.city.is_empty() {
            geo.city = found.city.clone();
        }
        if geo.asn == 0 {
            geo.asn = found.asn;
        }
        if geo.as_org.is_empty() {
            geo.as_org = found.as_org.clone();
        }
    }

    let (client_ip, client_ip_anonymized) = match client_ip_raw {
        Some(ip) if policy.anonymize_client_ip => (truncate_ip(ip), true),
        Some(ip) => (ip.to_string(), false),
        None => (String::new(), policy.anonymize_client_ip),
    };

    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0);
    let observed_at_unix_ms = parse_i64_param(params, &["rt.tstart", "observed_at_unix_ms"])
        .filter(|ts| {
            (now_ms.saturating_sub(MAX_OBSERVED_AT_PAST_MS)
                ..=now_ms.saturating_add(MAX_OBSERVED_AT_FUTURE_MS))
                .contains(ts)
        })
        .unwrap_or(now_ms);

    let lcp_ms = parse_f64_param(params, &["c.lcp", "lcp_ms", "lcp"]);
    let inp_ms = parse_f64_param(params, &["c.inp", "inp_ms", "inp"]);
    let cls = parse_f64_param(params, &["c.cls", "cls"]);
    let fcp_ms = parse_f64_param(params, &["c.fcp", "fcp_ms", "fcp"]);
    let ttfb_ms = parse_f64_param(params, &["c.ttfb", "ttfb_ms", "t_resp", "ttfb"]);
    let page_load_ms = parse_f64_param(params, &["t_done", "page_load_ms"]);
    let dom_ready_ms = parse_f64_param(params, &["t_page", "dom_ready_ms"]);
    let dns_ms =
        diff_ms(params, "nt_dns_end", "nt_dns_st").or_else(|| parse_f64_param(params, &["dns_ms"]));
    let connect_ms = diff_ms(params, "nt_con_end", "nt_con_st")
        .or_else(|| parse_f64_param(params, &["connect_ms"]));
    let tls_ms =
        diff_ms(params, "nt_con_end", "nt_ssl_st").or_else(|| parse_f64_param(params, &["tls_ms"]));

    let rage_clicks = parse_u32_param(params, &["c.e.rage", "c.rc", "rage_clicks"]).unwrap_or(0);
    let js_errors = parse_js_errors_count(params);
    let http_status =
        parse_u32_param(params, &["http.status_code", "http.status", "http_status"]).unwrap_or(0);
    let has_error = js_errors > 0 || http_status >= 400 || params.contains_key("err");

    let trace_id = validate_hex_id(
        params
            .get("sr.trace_id")
            .or_else(|| params.get("trace_id"))
            .map(String::as_str),
        32,
    );
    let span_id = validate_hex_id(
        params
            .get("sr.span_id")
            .or_else(|| params.get("span_id"))
            .map(String::as_str),
        16,
    );

    let user_agent = headers
        .get(USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .or_else(|| params.get("ua").map(String::as_str))
        .unwrap_or("")
        .chars()
        .take(512)
        .collect::<String>();

    let beacon_id = params
        .get("sr.beacon_id")
        .or_else(|| params.get("beacon_id"))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    let cdn_provider = if !st.cdn_provider.is_empty() {
        st.cdn_provider
    } else if from_trusted_proxy && headers.contains_key("akamai-edgescape") {
        "akamai".to_string()
    } else {
        String::new()
    };

    let initiator = params
        .get("http.initiator")
        .or_else(|| params.get("sr.initiator"))
        .or_else(|| params.get("initiator"))
        .cloned()
        .unwrap_or_else(|| "document".to_string());

    let mut beacon = RumBeaconV1 {
        beacon_id,
        observed_at_unix_ms,
        web_property_id: policy.web_property_id.clone(),
        canonical_origin: policy.canonical_origin.clone(),
        environment: policy.environment.clone(),
        url: scrubbed_u.url,
        host: scrubbed_u.host,
        path: scrubbed_u.path,
        metric_path: metric_path.clone(),
        referrer: scrubbed_r,
        page_group,
        initiator,
        trace_id,
        span_id,
        session_id: params.get("rt.si").cloned().unwrap_or_default(),
        user_agent,
        device_type: params.get("mob.etype").cloned().unwrap_or_default(),
        browser: String::new(),
        os: String::new(),
        lcp_ms,
        inp_ms,
        cls,
        fcp_ms,
        ttfb_ms,
        page_load_ms,
        dns_ms,
        connect_ms,
        tls_ms,
        dom_ready_ms,
        rage_clicks,
        js_errors,
        http_status,
        has_error,
        cdn_provider,
        cdn_cache_status: st.cdn_cache_status,
        cdn_edge_rtt_ms: st.cdn_edge_rtt_ms,
        cdn_origin_rtt_ms: st.cdn_origin_rtt_ms,
        cdn_pop: st.cdn_pop,
        server_timing_raw: server_timing_bounded,
        client_ip,
        client_ip_anonymized,
        country: geo.country,
        region: geo.region,
        city: geo.city,
        asn: geo.asn,
        as_org: geo.as_org,
        prefix_tag,
        attributes: HashMap::new(),
    };
    bound_beacon_columns(&mut beacon);

    let metric_batch = build_rum_metric_batch(policy, &beacon);
    Ok((beacon, metric_batch))
}

fn bound_beacon_columns(beacon: &mut RumBeaconV1) {
    let columns: [(&mut String, usize); 24] = [
        (&mut beacon.web_property_id, 64),
        (&mut beacon.beacon_id, 64),
        (&mut beacon.canonical_origin, 512),
        (&mut beacon.environment, 64),
        (&mut beacon.url, 4096),
        (&mut beacon.host, 256),
        (&mut beacon.path, 2048),
        (&mut beacon.metric_path, 1024),
        (&mut beacon.referrer, 4096),
        (&mut beacon.page_group, 1024),
        (&mut beacon.initiator, 128),
        (&mut beacon.session_id, 128),
        (&mut beacon.user_agent, 1024),
        (&mut beacon.device_type, 64),
        (&mut beacon.cdn_provider, 64),
        (&mut beacon.cdn_cache_status, 64),
        (&mut beacon.cdn_pop, 128),
        (&mut beacon.server_timing_raw, 1024),
        (&mut beacon.client_ip, 64),
        (&mut beacon.country, 16),
        (&mut beacon.region, 64),
        (&mut beacon.city, 128),
        (&mut beacon.as_org, 256),
        (&mut beacon.prefix_tag, 256),
    ];
    for (value, max_bytes) in columns {
        truncate_at_char_boundary(value, max_bytes);
    }
}

fn truncate_at_char_boundary(value: &mut String, max_bytes: usize) {
    if value.len() <= max_bytes {
        return;
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value.truncate(end);
}

pub fn build_rum_metric_batch(
    policy: &CompiledPropertyPolicy,
    beacon: &RumBeaconV1,
) -> Option<MetricBatch> {
    let observed_ns = u64::try_from(beacon.observed_at_unix_ms)
        .unwrap_or(0)
        .saturating_mul(1_000_000);

    let mut resource_attrs = vec![
        kv("web_property_id", &policy.web_property_id),
        kv("canonical_origin", &policy.canonical_origin),
        kv("environment", &policy.environment),
        kv("metric_path", &beacon.metric_path),
    ];
    if !beacon.prefix_tag.is_empty() {
        resource_attrs.push(kv("prefix_tag", &beacon.prefix_tag));
    }
    if !beacon.cdn_cache_status.is_empty() {
        resource_attrs.push(kv("cdn_cache_status", &beacon.cdn_cache_status));
    }
    if !beacon.country.is_empty() {
        resource_attrs.push(kv("country", &beacon.country));
    }
    if beacon.asn > 0 {
        resource_attrs.push(kv("asn", &beacon.asn.to_string()));
    }

    let mut metrics = Vec::new();
    let scalar_candidates = [
        ("rum.lcp_ms", beacon.lcp_ms, "ms"),
        ("rum.inp_ms", beacon.inp_ms, "ms"),
        ("rum.cls", beacon.cls, "1"),
        ("rum.fcp_ms", beacon.fcp_ms, "ms"),
        ("rum.ttfb_ms", beacon.ttfb_ms, "ms"),
        ("rum.akamai_edge_rtt_ms", beacon.cdn_edge_rtt_ms, "ms"),
        ("rum.akamai_origin_rtt_ms", beacon.cdn_origin_rtt_ms, "ms"),
    ];
    for (name, maybe_val, unit) in scalar_candidates {
        if let Some(value) = maybe_val {
            metrics.push(rum_gauge_metric(
                name,
                unit,
                value,
                observed_ns,
                &resource_attrs,
            ));
        }
    }
    if beacon.rage_clicks > 0 {
        metrics.push(rum_gauge_metric(
            "rum.rage_clicks",
            "1",
            f64::from(beacon.rage_clicks),
            observed_ns,
            &resource_attrs,
        ));
    }
    if beacon.js_errors > 0 {
        metrics.push(rum_gauge_metric(
            "rum.js_errors",
            "1",
            f64::from(beacon.js_errors),
            observed_ns,
            &resource_attrs,
        ));
    }

    if metrics.is_empty() {
        return None;
    }

    Some(MetricBatch {
        schema_version: METRIC_ENVELOPE_SCHEMA_VERSION.to_string(),
        resource: Some(MetricResource {
            service_name: policy.name.clone(),
            service_type: "web_property".to_string(),
            attributes: resource_attrs,
            ..Default::default()
        }),
        ingest_identity: Some(IngestIdentity {
            source: "boomerang-rum".to_string(),
            payload_kind: METRIC_ENVELOPE_SCHEMA_VERSION.to_string(),
            producer_id: policy.web_property_id.clone(),
            producer_kind: "rum-collector".to_string(),
            ..Default::default()
        }),
        ingress_id: beacon.beacon_id.clone(),
        ingress_timestamp_unix_nano: observed_ns,
        emitted_at_unix_nano: observed_ns,
        metrics,
    })
}

fn rum_gauge_metric(
    name: &str,
    unit: &str,
    value: f64,
    observed_ns: u64,
    attrs: &[StringMapEntry],
) -> Metric {
    Metric {
        name: name.to_string(),
        metric_type: "rum".to_string(),
        kind: MetricKind::Gauge as i32,
        unit: unit.to_string(),
        points: vec![MetricPoint {
            value,
            raw_value: value.to_string(),
            raw_value_type: MetricValueType::Double as i32,
            observed_at_unix_nano: observed_ns,
            attributes: attrs.to_vec(),
            ..Default::default()
        }],
        tags: attrs.to_vec(),
        ..Default::default()
    }
}

fn kv(key: &str, value: &str) -> StringMapEntry {
    StringMapEntry {
        key: key.to_string(),
        value: value.to_string(),
    }
}

fn parse_f64_param(params: &HashMap<String, String>, keys: &[&str]) -> Option<f64> {
    keys.iter()
        .find_map(|k| params.get(*k))
        .and_then(|raw| raw.trim().parse::<f64>().ok())
        .filter(|v| v.is_finite() && *v >= 0.0)
}

fn parse_i64_param(params: &HashMap<String, String>, keys: &[&str]) -> Option<i64> {
    keys.iter()
        .find_map(|k| params.get(*k))
        .and_then(|raw| raw.trim().parse::<i64>().ok())
}

fn parse_u32_param(params: &HashMap<String, String>, keys: &[&str]) -> Option<u32> {
    keys.iter()
        .find_map(|k| params.get(*k))
        .and_then(|raw| raw.trim().parse::<u32>().ok())
}

fn parse_js_errors_count(params: &HashMap<String, String>) -> u32 {
    if let Some(count) = parse_u32_param(params, &["js_errors"]) {
        return count;
    }
    if let Some(err_raw) = params.get("err") {
        let trimmed = err_raw.trim();
        if let Ok(n) = trimmed.parse::<u32>() {
            return n;
        }
        if let Ok(serde_json::Value::Array(items)) =
            serde_json::from_str::<serde_json::Value>(trimmed)
        {
            return items.len() as u32;
        }
        if !trimmed.is_empty() {
            return 1;
        }
    }
    0
}

fn diff_ms(params: &HashMap<String, String>, end_key: &str, start_key: &str) -> Option<f64> {
    let end = params.get(end_key)?.trim().parse::<f64>().ok()?;
    let start = params.get(start_key)?.trim().parse::<f64>().ok()?;
    if end.is_finite() && start.is_finite() && end >= start {
        Some(end - start)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rum::prefix::parse_cidr_list;
    use crate::rum_proto::{RumPrefixTagRule, WebPropertyRumPolicy, WebPropertyRumPolicySnapshot};
    use hyper::header::HeaderValue;

    fn test_policy_cache() -> (RumPolicyCache, CompiledPropertyPolicy) {
        let cache = RumPolicyCache::from_snapshot(WebPropertyRumPolicySnapshot {
            version: 1,
            generated_at_unix_ms: 1,
            properties: vec![WebPropertyRumPolicy {
                web_property_id: "01900000-0000-7000-8000-000000000001".to_string(),
                name: "Shop".to_string(),
                canonical_origin: "https://shop.example.com".to_string(),
                allowed_origins: vec![],
                allowed_query_keys: vec!["tab".to_string()],
                trace_propagate_origins: vec![],
                rum_site_key: "sr_rum_aaaaaaaaaaaaaaaa".to_string(),
                rum_enabled: true,
                rum_sample_rate: 1.0,
                anonymize_client_ip: true,
                environment: "production".to_string(),
                prefix_tags: vec![RumPrefixTagRule {
                    cidr: "198.51.100.0/24".to_string(),
                    tag: "site:branch-01".to_string(),
                }],
            }],
            global_prefix_tags: vec![],
        });
        let policy = cache.lookup("sr_rum_aaaaaaaaaaaaaaaa").unwrap();
        (cache, policy)
    }

    #[test]
    fn url_scrubbing_strips_query_and_fragment_preserving_allowlisted_keys() {
        let scrubbed = scrub_url(
            "https://Shop.Example.com/checkout?session_token=secret&tab=shipping&page=2#step2",
            &["tab".to_string()],
        )
        .unwrap();
        assert_eq!(
            scrubbed.url,
            "https://shop.example.com/checkout?tab=shipping"
        );
        assert_eq!(scrubbed.host, "shop.example.com");
        assert_eq!(scrubbed.path, "/checkout");

        let default_scrubbed = scrub_url(
            "https://shop.example.com/checkout?session_token=secret#step2",
            &[],
        )
        .unwrap();
        assert_eq!(default_scrubbed.url, "https://shop.example.com/checkout");
        assert_eq!(default_scrubbed.path, "/checkout");
    }

    #[test]
    fn metric_path_normalizes_numeric_uuid_and_hex_segments() {
        assert_eq!(
            normalize_metric_path("/orders/12345/receipt"),
            "/orders/:id/receipt"
        );
        assert_eq!(
            normalize_metric_path("/users/550e8400-e29b-41d4-a716-446655440000/profile"),
            "/users/:id/profile"
        );
        assert_eq!(normalize_metric_path("/"), "/");
    }

    #[test]
    fn parses_akamai_server_timing_and_edgescape() {
        let st = parse_server_timing(
            "cdn-cache;desc=MISS, edge;dur=12.5, origin;dur=340.2, ak_p;desc=iad-01",
        );
        assert_eq!(st.cdn_cache_status, "MISS");
        assert_eq!(st.cdn_edge_rtt_ms, Some(12.5));
        assert_eq!(st.cdn_origin_rtt_ms, Some(340.2));
        assert_eq!(st.cdn_pop, "iad-01");
        assert_eq!(st.cdn_provider, "akamai");

        let geo = parse_akamai_edgescape(
            "country_code=US,region_code=CA,city=SANFRANCISCO,asnum=20940,network=AKAMAI",
        );
        assert_eq!(geo.country, "US");
        assert_eq!(geo.region, "CA");
        assert_eq!(geo.city, "SANFRANCISCO");
        assert_eq!(geo.asn, 20940);
        assert_eq!(geo.as_org, "AKAMAI");
    }

    #[test]
    fn trusted_proxies_gate_spoofed_headers_and_lookup_precedes_ip_truncation() {
        let (cache, policy) = test_policy_cache();
        let trusted = parse_cidr_list(&["10.0.0.0/8".to_string()]);
        let params = parse_form_urlencoded(
            "u=https://shop.example.com/orders/98765?token=secret#frag&c.lcp=1450&c.inp=80&c.cls=0.04&servertiming=cdn-cache%3Bdesc%3DMISS%2C+edge%3Bdur%3D12%2C+origin%3Bdur%3D340&sr.trace_id=0123456789abcdef0123456789abcdef",
        );

        let mut headers = HeaderMap::new();
        headers.insert("true-client-ip", HeaderValue::from_static("198.51.100.42"));
        headers.insert(
            "akamai-edgescape",
            HeaderValue::from_static("country_code=US,asnum=64512"),
        );

        // Untrusted peer IP ignores spoofed True-Client-IP & Akamai-Edgescape.
        let (untrusted_beacon, _) = build_beacon_and_metrics(
            &params,
            &headers,
            Some("203.0.113.77".parse().unwrap()),
            &trusted,
            &policy,
            &cache,
            None,
        )
        .unwrap();
        assert_eq!(untrusted_beacon.client_ip, "203.0.113.0");
        assert_eq!(untrusted_beacon.prefix_tag, "");
        assert_eq!(untrusted_beacon.asn, 0);

        // Trusted proxy honors True-Client-IP, runs prefix_tags LPM before truncation, then zeroes /24.
        let (trusted_beacon, batch) = build_beacon_and_metrics(
            &params,
            &headers,
            Some("10.1.2.3".parse().unwrap()),
            &trusted,
            &policy,
            &cache,
            None,
        )
        .unwrap();
        assert_eq!(trusted_beacon.url, "https://shop.example.com/orders/98765");
        assert_eq!(trusted_beacon.metric_path, "/orders/:id");
        assert_eq!(trusted_beacon.prefix_tag, "site:branch-01");
        assert_eq!(trusted_beacon.client_ip, "198.51.100.0");
        assert!(trusted_beacon.client_ip_anonymized);
        assert_eq!(trusted_beacon.country, "US");
        assert_eq!(trusted_beacon.asn, 64512);
        assert_eq!(trusted_beacon.cdn_cache_status, "MISS");
        assert_eq!(trusted_beacon.cdn_edge_rtt_ms, Some(12.0));
        assert_eq!(trusted_beacon.cdn_origin_rtt_ms, Some(340.0));
        assert_eq!(trusted_beacon.trace_id, "0123456789abcdef0123456789abcdef");

        let batch = batch.unwrap();
        let names: Vec<&str> = batch.metrics.iter().map(|m| m.name.as_str()).collect();
        assert!(names.contains(&"rum.lcp_ms"));
        assert!(names.contains(&"rum.inp_ms"));
        assert!(names.contains(&"rum.cls"));
        assert!(names.contains(&"rum.akamai_edge_rtt_ms"));
        assert!(names.contains(&"rum.akamai_origin_rtt_ms"));
    }

    #[test]
    fn url_scrubbing_preserves_ipv6_literals_and_non_default_ports_and_strips_defaults() {
        let allowed = vec!["page".to_string()];

        let ipv6 = scrub_url(
            "https://[2001:db8::1]:8443/checkout?page=2&token=secret",
            &allowed,
        )
        .unwrap();
        assert_eq!(ipv6.url, "https://[2001:db8::1]:8443/checkout?page=2");
        assert_eq!(ipv6.host, "[2001:db8::1]");
        assert_eq!(ipv6.path, "/checkout");

        let ipv6_default =
            scrub_url("https://[2001:DB8::1]:443/checkout?token=secret", &allowed).unwrap();
        assert_eq!(ipv6_default.url, "https://[2001:db8::1]/checkout");
        assert_eq!(ipv6_default.host, "[2001:db8::1]");
        assert_eq!(ipv6_default.path, "/checkout");

        let non_default = scrub_url("https://shop.example:8443/checkout?page=2", &allowed).unwrap();
        assert_eq!(non_default.url, "https://shop.example:8443/checkout?page=2");
        assert_eq!(non_default.host, "shop.example");
        assert_eq!(non_default.path, "/checkout");

        let default_https =
            scrub_url("https://shop.example:443/checkout?page=2", &allowed).unwrap();
        assert_eq!(default_https.url, "https://shop.example/checkout?page=2");
        assert_eq!(default_https.host, "shop.example");

        let default_http = scrub_url("http://shop.example:80/checkout?page=2", &allowed).unwrap();
        assert_eq!(default_http.url, "http://shop.example/checkout?page=2");
        assert_eq!(default_http.host, "shop.example");

        let ipv4_port = scrub_url("http://192.0.2.10:8080/health?token=secret", &[]).unwrap();
        assert_eq!(ipv4_port.url, "http://192.0.2.10:8080/health");
        assert_eq!(ipv4_port.host, "192.0.2.10");
    }

    #[test]
    fn url_scrubbing_rejects_non_http_schemes_while_allowing_relative_paths() {
        assert_eq!(scrub_url("javascript:alert(1)?token=abc", &[]), None);
        assert_eq!(scrub_url("JAVASCRIPT:alert(1)", &[]), None);
        assert_eq!(
            scrub_url("data:text/html,<script>alert(1)</script>", &[]),
            None
        );
        assert_eq!(scrub_url("ftp://files.example/archive.tgz", &[]), None);
        assert_eq!(scrub_url("ftp:archive.tgz", &[]), None);

        let rel = scrub_url("/checkout/step1?token=secret", &[]).unwrap();
        assert_eq!(rel.url, "/checkout/step1");
        assert_eq!(rel.host, "");
        assert_eq!(rel.path, "/checkout/step1");

        let path_only =
            scrub_url("checkout/step2?page=2&token=secret", &["page".to_string()]).unwrap();
        assert_eq!(path_only.url, "/checkout/step2?page=2");
        assert_eq!(path_only.host, "");
        assert_eq!(path_only.path, "/checkout/step2");

        let colon_in_subpath = scrub_url("/items/a:b?token=secret", &[]).unwrap();
        assert_eq!(colon_in_subpath.url, "/items/a:b");
        assert_eq!(colon_in_subpath.path, "/items/a:b");
    }

    #[test]
    fn url_scrubbing_rejects_protocol_relative_and_control_chars_and_preserves_scheme_in_relative_path()
     {
        assert_eq!(scrub_url("//evil.example/foo?token=s", &[]), None);
        assert_eq!(scrub_url("///evil.example/foo?token=s", &[]), None);
        assert_eq!(scrub_url("java\tscript:alert(1)", &[]), None);
        assert_eq!(scrub_url("/checkout\n?token=s", &[]), None);
        assert_eq!(scrub_url("ftp://files.example/archive.tgz", &[]), None);

        let proxied = scrub_url("/proxy/https://target.example/a?token=s", &[]).unwrap();
        assert_eq!(proxied.url, "/proxy/https://target.example/a");
        assert_eq!(proxied.host, "");
        assert_eq!(proxied.path, "/proxy/https://target.example/a");

        let dot_proxied = scrub_url("./proxy/https://target.example/a?token=s", &[]).unwrap();
        assert_eq!(dot_proxied.path, "/./proxy/https://target.example/a");

        let parent_proxied = scrub_url("../proxy/https://target.example/a?token=s", &[]).unwrap();
        assert_eq!(parent_proxied.path, "/../proxy/https://target.example/a");
    }

    fn now_unix_ms() -> i64 {
        i64::try_from(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis(),
        )
        .unwrap()
    }

    fn build_from_query(query: &str) -> (RumBeaconV1, Option<MetricBatch>) {
        let (cache, policy) = test_policy_cache();
        let params = parse_form_urlencoded(query);
        build_beacon_and_metrics(
            &params,
            &HeaderMap::new(),
            Some("203.0.113.77".parse().unwrap()),
            &[],
            &policy,
            &cache,
            None,
        )
        .unwrap()
    }

    #[test]
    fn client_observed_at_outside_server_window_falls_back_to_server_time() {
        let hour_ms = 60 * 60 * 1000;
        let day_ms = 24 * hour_ms;
        let cases = [
            (now_unix_ms() - hour_ms, true),
            (now_unix_ms() + 60 * 1000, true),
            (now_unix_ms() + 365 * day_ms, false),
            (now_unix_ms() + hour_ms, false),
            (now_unix_ms() - 30 * day_ms, false),
            (1_100_000_000_000, false),
        ];

        for (client_ms, accepted) in cases {
            let before = now_unix_ms();
            let (beacon, batch) = build_from_query(&format!(
                "u=https://shop.example.com/&c.lcp=1200&rt.tstart={client_ms}"
            ));
            let after = now_unix_ms();

            if accepted {
                assert_eq!(beacon.observed_at_unix_ms, client_ms);
            } else {
                assert!(
                    (before..=after).contains(&beacon.observed_at_unix_ms),
                    "client timestamp {client_ms} should be replaced by server time"
                );
            }

            let expected_ns = u64::try_from(beacon.observed_at_unix_ms).unwrap() * 1_000_000;
            let batch = batch.unwrap();
            assert!(!batch.metrics.is_empty());
            for metric in &batch.metrics {
                for point in &metric.points {
                    assert_eq!(point.observed_at_unix_nano, expected_ns);
                }
            }
        }
    }

    #[test]
    fn oversized_client_fields_are_truncated_to_column_widths_on_char_boundaries() {
        let wide = "\u{e9}".repeat(300);
        let encoded = urlencoding::encode(&wide).into_owned();
        let long_path = "a".repeat(5000);
        let (beacon, _) = build_from_query(&format!(
            "u=https://shop.example.com/{long_path}&sr.beacon_id={encoded}&rt.si={encoded}&http.initiator={encoded}&mob.etype={encoded}"
        ));

        for (value, max_bytes) in [
            (&beacon.beacon_id, 64),
            (&beacon.session_id, 128),
            (&beacon.initiator, 128),
            (&beacon.device_type, 64),
            (&beacon.url, 4096),
            (&beacon.path, 2048),
        ] {
            assert!(
                value.len() <= max_bytes,
                "{} bytes > {max_bytes}",
                value.len()
            );
            assert!(value.len() > max_bytes - 4);
        }
        assert_eq!(beacon.beacon_id, "\u{e9}".repeat(32));
        assert_eq!(beacon.session_id, "\u{e9}".repeat(64));
        assert!(beacon.url.starts_with("https://shop.example.com/aaa"));

        let (short, _) = build_from_query(
            "u=https://shop.example.com/&sr.beacon_id=b-1&rt.si=s-1&mob.etype=mobile",
        );
        assert_eq!(short.beacon_id, "b-1");
        assert_eq!(short.session_id, "s-1");
        assert_eq!(short.device_type, "mobile");
        assert_eq!(short.initiator, "document");
    }

    #[test]
    fn multipart_decoder_accepts_case_insensitive_boundary_parameter() {
        let body = b"--MyBoundary\r\nContent-Disposition: form-data; name=\"sr.key\"\r\n\r\nsr_rum_test\r\n--MyBoundary\r\nContent-Disposition: form-data; name=\"u\"\r\n\r\nhttps://shop.example/checkout?token=secret\r\n--MyBoundary--\r\n";
        let params =
            decode_beacon_params("multipart/form-data; BOUNDARY=\"MyBoundary\"", body).unwrap();
        assert_eq!(
            params.get("sr.key").map(String::as_str),
            Some("sr_rum_test")
        );
        assert_eq!(
            params.get("u").map(String::as_str),
            Some("https://shop.example/checkout?token=secret")
        );
    }
}
