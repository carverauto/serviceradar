pub mod policy;
pub mod prefix;
pub mod rate_limit;
pub mod scrub;

use std::io::Read;
use std::net::IpAddr;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Bytes;
use hyper::header::{self, HeaderMap, HeaderValue};
use hyper::{Method, Response, StatusCode};

use crate::ServiceRadarCollector;
use crate::config::RumConfig;
use crate::metrics;
use policy::RumPolicyCache;
use prefix::{Prefix, parse_cidr_list};
use rate_limit::RumRateLimiter;
use scrub::{StaticGeoAsn, build_beacon_and_metrics, decode_beacon_params, parse_form_urlencoded};

pub const RUM_BEACON_PATH: &str = "/rum/v1/beacon";

#[derive(Debug)]
pub struct RumRuntime {
    pub config: RumConfig,
    pub policy: Arc<RumPolicyCache>,
    pub rate_limiter: Arc<RumRateLimiter>,
    pub trusted_proxies: Vec<Prefix>,
    pub static_geo: Option<Arc<StaticGeoAsn>>,
    sample_counter: AtomicU64,
}

impl RumRuntime {
    pub fn new(config: RumConfig, policy: Arc<RumPolicyCache>) -> Self {
        let trusted_proxies = parse_cidr_list(&config.trusted_proxies);
        let rate_limiter = Arc::new(RumRateLimiter::from_config(&config));
        let static_geo = config
            .static_geo_asn_path
            .as_deref()
            .and_then(|p| StaticGeoAsn::from_file(Path::new(p)).ok())
            .map(Arc::new);
        Self {
            config,
            policy,
            rate_limiter,
            trusted_proxies,
            static_geo,
            sample_counter: AtomicU64::new(0),
        }
    }

    fn should_sample(&self, sample_rate: f64) -> bool {
        if sample_rate >= 1.0 {
            return true;
        }
        if sample_rate <= 0.0 {
            return false;
        }
        let seq = self.sample_counter.fetch_add(1, Ordering::Relaxed);
        let bucket = (seq % 10_000) as f64 / 10_000.0;
        bucket < sample_rate
    }
}

pub async fn handle_rum_request<B>(
    method: &Method,
    query: Option<&str>,
    headers: &HeaderMap,
    body: B,
    peer_ip: Option<IpAddr>,
    runtime: &RumRuntime,
    collector: &ServiceRadarCollector,
) -> Response<Full<Bytes>>
where
    B: hyper::body::Body<Data = Bytes> + Send,
    B::Error: std::error::Error + Send + Sync + 'static,
{
    if !runtime.config.enabled {
        return rum_response(StatusCode::NOT_FOUND, "RUM endpoint disabled", None);
    }

    let request_origin = headers
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let query_params = query.map(parse_form_urlencoded).unwrap_or_default();
    let header_key = headers
        .get("x-serviceradar-rum-key")
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let query_key = query_params
        .get("key")
        .or_else(|| query_params.get("site_key"))
        .or_else(|| query_params.get("sr.key"))
        .map(String::as_str);

    if method == Method::OPTIONS {
        let Some(origin) = request_origin else {
            return rum_response(StatusCode::FORBIDDEN, "Origin required", None);
        };
        let allowed = match header_key.or(query_key) {
            Some(key) => match runtime.policy.lookup(key) {
                Some(policy) if policy.rum_enabled => {
                    runtime.policy.validate_origin(&policy, Some(origin))
                }
                _ => false,
            },
            None => runtime.policy.any_origin_allowed(origin),
        };
        if !allowed {
            metrics::record_rejected("rum_beacons", "disallowed_origin", 1);
            return rum_response(StatusCode::FORBIDDEN, "disallowed Origin", None);
        }
        return preflight_rum_response(origin);
    }

    if method != Method::POST {
        return rum_response(
            StatusCode::METHOD_NOT_ALLOWED,
            "only POST and OPTIONS are supported on /rum/v1/beacon",
            None,
        );
    }

    // Strict 64 KiB body cap before buffering excess bytes.
    let max_body = runtime.config.max_body_bytes.max(1);
    let raw_body = match Limited::new(body, max_body).collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(err) => {
            if err
                .downcast_ref::<http_body_util::LengthLimitError>()
                .is_some()
            {
                metrics::record_rejected("rum_beacons", "oversize", 1);
                return rum_response(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "RUM beacon exceeds 64 KiB limit",
                    None,
                );
            }
            metrics::record_rejected("rum_beacons", "bad_payload", 1);
            return rum_response(StatusCode::BAD_REQUEST, "failed to read RUM body", None);
        }
    };

    let content_encoding = headers
        .get(header::CONTENT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let decoded_body = match content_encoding.as_str() {
        "" | "identity" => raw_body,
        "gzip" => match gunzip_bounded(&raw_body, max_body) {
            Ok(bytes) => bytes,
            Err(GunzipLimit::TooLarge) => {
                metrics::record_rejected("rum_beacons", "oversize", 1);
                return rum_response(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "decompressed RUM beacon exceeds 64 KiB limit",
                    None,
                );
            }
            Err(GunzipLimit::Invalid) => {
                metrics::record_rejected("rum_beacons", "bad_payload", 1);
                return rum_response(StatusCode::BAD_REQUEST, "invalid gzip RUM body", None);
            }
        },
        _ => {
            return rum_response(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "unsupported Content-Encoding",
                None,
            );
        }
    };

    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let mut params = match decode_beacon_params(content_type, &decoded_body) {
        Ok(map) => map,
        Err(msg) => {
            metrics::record_rejected("rum_beacons", "bad_payload", 1);
            let status = if msg.starts_with("unsupported RUM content-type") {
                StatusCode::UNSUPPORTED_MEDIA_TYPE
            } else {
                StatusCode::BAD_REQUEST
            };
            return rum_response(status, &msg, None);
        }
    };
    for (k, v) in query_params {
        params.entry(k).or_insert(v);
    }

    let site_key = header_key
        .or_else(|| {
            params
                .get("sr.key")
                .or_else(|| params.get("key"))
                .or_else(|| params.get("site_key"))
                .map(String::as_str)
        })
        .map(str::trim)
        .unwrap_or("");

    if site_key.is_empty() {
        metrics::record_rejected("rum_beacons", "unknown_key", 1);
        return rum_response(StatusCode::UNAUTHORIZED, "missing rum_site_key", None);
    }

    let Some(policy) = runtime.policy.lookup(site_key) else {
        metrics::record_rejected("rum_beacons", "unknown_key", 1);
        return rum_response(StatusCode::UNAUTHORIZED, "unknown rum_site_key", None);
    };

    if !policy.rum_enabled {
        metrics::record_rejected("rum_beacons", "disabled_property", 1);
        return rum_response(StatusCode::FORBIDDEN, "RUM disabled for web property", None);
    }

    let effective_origin = request_origin.map(str::to_string).or_else(|| {
        headers
            .get(header::REFERER)
            .and_then(|v| v.to_str().ok())
            .and_then(policy::normalize_origin)
    });
    if !runtime
        .policy
        .validate_origin(&policy, effective_origin.as_deref())
    {
        metrics::record_rejected("rum_beacons", "disallowed_origin", 1);
        return rum_response(StatusCode::FORBIDDEN, "disallowed Origin", None);
    }
    let allow_origin = effective_origin.as_deref();

    let (client_ip_for_limit, _) =
        scrub::resolve_client_ip(peer_ip, headers, &runtime.trusted_proxies);
    if let Err(retry_after) = runtime.rate_limiter.check(site_key, client_ip_for_limit) {
        metrics::record_rejected("rum_beacons", "rate_limited", 1);
        return rate_limited_response(retry_after, allow_origin);
    }

    if !runtime.should_sample(policy.rum_sample_rate) {
        return no_content_response(allow_origin);
    }

    let (beacon, metric_batch) = match build_beacon_and_metrics(
        &params,
        headers,
        peer_ip,
        &runtime.trusted_proxies,
        &policy,
        &runtime.policy,
        runtime.static_geo.as_deref(),
    ) {
        Ok(res) => res,
        Err(msg) => {
            metrics::record_rejected("rum_beacons", "bad_payload", 1);
            return rum_response(StatusCode::BAD_REQUEST, &msg, allow_origin);
        }
    };

    metrics::record_received("rum_beacons", 1);
    match collector
        .handle_rum_beacon(&policy.web_property_id, beacon, metric_batch)
        .await
    {
        Ok(()) => no_content_response(allow_origin),
        Err(e) => rum_response(
            StatusCode::SERVICE_UNAVAILABLE,
            &format!("failed to publish RUM beacon: {e}"),
            allow_origin,
        ),
    }
}

enum GunzipLimit {
    TooLarge,
    Invalid,
}

fn gunzip_bounded(data: &[u8], max_bytes: usize) -> Result<Bytes, GunzipLimit> {
    let mut decoder = flate2::read::GzDecoder::new(data);
    let mut out = Vec::new();
    let mut buf = [0u8; 8 * 1024];
    loop {
        let n = decoder.read(&mut buf).map_err(|_| GunzipLimit::Invalid)?;
        if n == 0 {
            break;
        }
        out.extend_from_slice(&buf[..n]);
        if out.len() > max_bytes {
            return Err(GunzipLimit::TooLarge);
        }
    }
    Ok(Bytes::from(out))
}

fn apply_rum_cors(
    mut builder: hyper::http::response::Builder,
    allow_origin: Option<&str>,
) -> hyper::http::response::Builder {
    builder = builder.header(header::VARY, "Origin");
    if let Some(origin) = allow_origin
        && let Ok(val) = HeaderValue::from_str(origin)
    {
        builder = builder.header(header::ACCESS_CONTROL_ALLOW_ORIGIN, val);
    }
    builder
}

fn preflight_rum_response(allow_origin: &str) -> Response<Full<Bytes>> {
    apply_rum_cors(
        Response::builder()
            .status(StatusCode::NO_CONTENT)
            .header(header::ACCESS_CONTROL_ALLOW_METHODS, "POST, OPTIONS")
            .header(
                header::ACCESS_CONTROL_ALLOW_HEADERS,
                "Content-Type, Content-Encoding, X-Serviceradar-Rum-Key",
            )
            .header(header::ACCESS_CONTROL_MAX_AGE, "3600"),
        Some(allow_origin),
    )
    .body(Full::new(Bytes::new()))
    .unwrap()
}

fn no_content_response(allow_origin: Option<&str>) -> Response<Full<Bytes>> {
    apply_rum_cors(
        Response::builder().status(StatusCode::NO_CONTENT),
        allow_origin,
    )
    .body(Full::new(Bytes::new()))
    .unwrap()
}

fn rate_limited_response(retry_after: u64, allow_origin: Option<&str>) -> Response<Full<Bytes>> {
    apply_rum_cors(
        Response::builder()
            .status(StatusCode::TOO_MANY_REQUESTS)
            .header(header::RETRY_AFTER, retry_after.to_string())
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8"),
        allow_origin,
    )
    .body(Full::new(Bytes::from("rate limit exceeded")))
    .unwrap()
}

fn rum_response(
    status: StatusCode,
    message: &str,
    allow_origin: Option<&str>,
) -> Response<Full<Bytes>> {
    apply_rum_cors(
        Response::builder()
            .status(status)
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8"),
        allow_origin,
    )
    .body(Full::new(Bytes::from(message.to_owned())))
    .unwrap()
}
