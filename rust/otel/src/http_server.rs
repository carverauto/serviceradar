//! OTLP/HTTP listener (default port 4318).
//!
//! Serves the standard OTLP/HTTP endpoints:
//!   POST /v1/traces, POST /v1/logs, POST /v1/metrics
//!
//! Supported request encoding: binary protobuf (`application/x-protobuf`),
//! optionally gzip Content-Encoding. OTLP/JSON is intentionally NOT
//! supported (prost has no canonical protobuf-JSON transcoding); JSON
//! requests receive 415 with a message pointing at protobuf or gRPC.
//!
//! Responses are protobuf-encoded `Export*ServiceResponse` messages with
//! OTLP partial_success semantics. CORS is permissive by default
//! (`allowed_origins = ["*"]`) so browser-based exporters work out of the
//! box; restrict it for public deployments.

use std::convert::Infallible;
use std::io::Read;
use std::net::SocketAddr;
use std::sync::Arc;

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::header::{self, HeaderMap, HeaderValue};
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use hyper_util::server::conn::auto::Builder as ConnBuilder;
use log::{debug, info};
use prost::Message;
use tokio::net::TcpListener;

use crate::ServiceRadarCollector;
use crate::auth::IngestAuth;
use crate::config::Config;
use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use crate::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;
use crate::output::IngestContext;

const CONTENT_TYPE_PROTOBUF: &str = "application/x-protobuf";

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Server TLS identity (PEM-encoded) reused from the gRPC listener so the
/// OTLP/HTTP endpoint presents the same certificate.
#[derive(Clone)]
pub struct TlsIdentityPem {
    pub cert_pem: Vec<u8>,
    pub key_pem: Vec<u8>,
}

#[derive(Clone)]
pub struct HttpServerOptions {
    pub addr: SocketAddr,
    pub allowed_origins: Vec<String>,
    pub max_request_bytes: usize,
    pub tls_identity: Option<TlsIdentityPem>,
    /// Ingestion-token authentication shared with the gRPC listener
    /// (`[auth]`); [`IngestAuth::disabled`] when enforcement is off.
    pub auth: Arc<IngestAuth>,
}

impl HttpServerOptions {
    /// Builds listener options from the collector config. Returns `None`
    /// when the HTTP listener is disabled. The gRPC TLS server certificate
    /// is reused when configured and `server.http.tls_enabled` is true
    /// (the default); otherwise the listener is plaintext. Disabling
    /// `tls_enabled` supports running behind a TLS-terminating gateway.
    pub fn from_config(config: &Config) -> Result<Option<Self>, BoxError> {
        if !config.server.http.enabled {
            return Ok(None);
        }

        let addr = config
            .http_address()
            .parse()
            .map_err(|e| format!("invalid OTLP/HTTP bind address: {e}"))?;

        let tls_identity = if !config.server.http.tls_enabled {
            None
        } else {
            match &config.grpc_tls {
                Some(tls) => Some(TlsIdentityPem {
                    cert_pem: std::fs::read(&tls.cert_file).map_err(|e| {
                        format!(
                            "failed to read TLS certificate '{}' for OTLP/HTTP listener: {e}",
                            tls.cert_file
                        )
                    })?,
                    key_pem: std::fs::read(&tls.key_file).map_err(|e| {
                        format!(
                            "failed to read TLS key '{}' for OTLP/HTTP listener: {e}",
                            tls.key_file
                        )
                    })?,
                }),
                None => None,
            }
        };

        let auth = IngestAuth::from_config(&config.auth)
            .map_err(|e| format!("invalid [auth] configuration: {e}"))?;

        Ok(Some(Self {
            addr,
            allowed_origins: config.server.http.allowed_origins.clone(),
            max_request_bytes: config.server.max_request_bytes,
            tls_identity,
            auth: Arc::new(auth),
        }))
    }
}

/// Starts the OTLP/HTTP listener. Runs until the process exits.
pub async fn start_http_server(
    options: HttpServerOptions,
    collector: ServiceRadarCollector,
) -> Result<(), BoxError> {
    let listener = TcpListener::bind(options.addr).await?;
    let tls_acceptor = match &options.tls_identity {
        Some(identity) => Some(build_tls_acceptor(identity)?),
        None => None,
    };

    info!(
        "OTLP/HTTP listener on {} (tls: {}, max request size: {} bytes)",
        options.addr,
        tls_acceptor.is_some(),
        options.max_request_bytes
    );

    let shared = Arc::new((options, collector));

    loop {
        let (stream, peer) = listener.accept().await?;
        let shared = Arc::clone(&shared);
        let tls_acceptor = tls_acceptor.clone();

        tokio::spawn(async move {
            let service = service_fn(move |req: Request<Incoming>| {
                let shared = Arc::clone(&shared);
                async move {
                    let (options, collector) = &*shared;
                    Ok::<_, Infallible>(handle_request(req, options, collector).await)
                }
            });

            let builder = ConnBuilder::new(hyper_util::rt::TokioExecutor::new());
            let result = match tls_acceptor {
                Some(acceptor) => match acceptor.accept(stream).await {
                    Ok(tls_stream) => {
                        builder
                            .serve_connection(TokioIo::new(tls_stream), service)
                            .await
                    }
                    Err(e) => {
                        debug!("OTLP/HTTP TLS handshake from {peer} failed: {e}");
                        return;
                    }
                },
                None => {
                    builder
                        .serve_connection(TokioIo::new(stream), service)
                        .await
                }
            };

            if let Err(e) = result {
                debug!("OTLP/HTTP connection from {peer} ended with error: {e:?}");
            }
        });
    }
}

fn build_tls_acceptor(identity: &TlsIdentityPem) -> Result<tokio_rustls::TlsAcceptor, BoxError> {
    let certs = rustls_pemfile::certs(&mut identity.cert_pem.as_slice())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("failed to parse TLS certificate for OTLP/HTTP listener: {e}"))?;
    if certs.is_empty() {
        return Err("no certificates found in TLS cert file for OTLP/HTTP listener".into());
    }
    let key = rustls_pemfile::private_key(&mut identity.key_pem.as_slice())
        .map_err(|e| format!("failed to parse TLS key for OTLP/HTTP listener: {e}"))?
        .ok_or("no private key found in TLS key file for OTLP/HTTP listener")?;

    let mut config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| format!("invalid TLS identity for OTLP/HTTP listener: {e}"))?;
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

    Ok(tokio_rustls::TlsAcceptor::from(Arc::new(config)))
}

async fn handle_request(
    req: Request<Incoming>,
    options: &HttpServerOptions,
    collector: &ServiceRadarCollector,
) -> Response<Full<Bytes>> {
    let origin = req
        .headers()
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let cors_origin = resolve_cors_origin(&options.allowed_origins, origin.as_deref());

    let (parts, body) = req.into_parts();
    let body = match Limited::new(body, options.max_request_bytes)
        .collect()
        .await
    {
        Ok(collected) => collected.to_bytes(),
        Err(e) => {
            return if e
                .downcast_ref::<http_body_util::LengthLimitError>()
                .is_some()
            {
                error_response(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    format!(
                        "request body exceeds max_request_bytes ({})",
                        options.max_request_bytes
                    ),
                    cors_origin,
                )
            } else {
                error_response(
                    StatusCode::BAD_REQUEST,
                    "failed to read request body".to_string(),
                    cors_origin,
                )
            };
        }
    };

    handle_otlp(
        &parts.method,
        parts.uri.path(),
        &parts.headers,
        body,
        options,
        collector,
        cors_origin,
    )
    .await
}

/// Transport-independent OTLP/HTTP request handler (body already collected),
/// kept separate from hyper plumbing so it is directly unit-testable.
async fn handle_otlp(
    method: &Method,
    path: &str,
    headers: &HeaderMap,
    body: Bytes,
    options: &HttpServerOptions,
    collector: &ServiceRadarCollector,
    cors_origin: Option<String>,
) -> Response<Full<Bytes>> {
    // CORS preflight stays unauthenticated so browser SDKs can negotiate
    // before sending credentialed exports.
    if method == Method::OPTIONS {
        return preflight_response(cors_origin);
    }

    // Ingestion authentication (no-op when [auth] enforcement is off; a
    // matching token still resolves the sender identity for attribution).
    let credential = crate::auth::credential_from_http_headers(headers);
    let ctx = match options.auth.authenticate(credential.as_deref()) {
        Ok(identity) => IngestContext { identity },
        Err(e) => {
            return error_response(
                StatusCode::UNAUTHORIZED,
                e.message().to_string(),
                cors_origin,
            );
        }
    };

    if method != Method::POST {
        return error_response(
            StatusCode::METHOD_NOT_ALLOWED,
            "only POST is supported on OTLP/HTTP endpoints".to_string(),
            cors_origin,
        );
    }

    if !matches!(path, "/v1/traces" | "/v1/logs" | "/v1/metrics") {
        return error_response(
            StatusCode::NOT_FOUND,
            "unknown path; OTLP/HTTP endpoints are /v1/traces, /v1/logs, /v1/metrics".to_string(),
            cors_origin,
        );
    }

    // Content-Type: binary protobuf only. OTLP/JSON would require canonical
    // protobuf-JSON transcoding that prost does not provide.
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    match content_type.as_str() {
        CONTENT_TYPE_PROTOBUF | "application/protobuf" => {}
        "application/json" => {
            return error_response(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "OTLP/JSON is not supported; send binary OTLP protobuf (Content-Type: \
                 application/x-protobuf) or use OTLP/gRPC on the gRPC port"
                    .to_string(),
                cors_origin,
            );
        }
        other => {
            return error_response(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                format!("unsupported content-type '{other}'; expected application/x-protobuf"),
                cors_origin,
            );
        }
    }

    // Content-Encoding: identity or gzip (the OTel SDK/Collector default).
    let content_encoding = headers
        .get(header::CONTENT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let body = match content_encoding.as_str() {
        "" | "identity" => body,
        "gzip" => match gunzip(&body, options.max_request_bytes) {
            Ok(decompressed) => decompressed,
            Err(GunzipError::TooLarge) => {
                return error_response(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    format!(
                        "decompressed request body exceeds max_request_bytes ({})",
                        options.max_request_bytes
                    ),
                    cors_origin,
                );
            }
            Err(GunzipError::Invalid) => {
                return error_response(
                    StatusCode::BAD_REQUEST,
                    "invalid gzip request body".to_string(),
                    cors_origin,
                );
            }
        },
        other => {
            return error_response(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                format!("unsupported content-encoding '{other}'; use gzip or identity"),
                cors_origin,
            );
        }
    };

    match path {
        "/v1/traces" => {
            let request = match ExportTraceServiceRequest::decode(body) {
                Ok(request) => request,
                Err(e) => return decode_error_response(e, cors_origin),
            };
            match collector.handle_traces(request, &ctx).await {
                Ok(response) => protobuf_response(response.encode_to_vec(), cors_origin),
                Err(e) => retryable_error_response(e.message, cors_origin),
            }
        }
        "/v1/logs" => {
            let request = match ExportLogsServiceRequest::decode(body) {
                Ok(request) => request,
                Err(e) => return decode_error_response(e, cors_origin),
            };
            match collector.handle_logs(request, &ctx).await {
                Ok(response) => protobuf_response(response.encode_to_vec(), cors_origin),
                Err(e) => retryable_error_response(e.message, cors_origin),
            }
        }
        "/v1/metrics" => {
            let request = match ExportMetricsServiceRequest::decode(body) {
                Ok(request) => request,
                Err(e) => return decode_error_response(e, cors_origin),
            };
            match collector.handle_metrics(request, &ctx).await {
                Ok(response) => protobuf_response(response.encode_to_vec(), cors_origin),
                Err(e) => retryable_error_response(e.message, cors_origin),
            }
        }
        _ => unreachable!("path validated above"),
    }
}

enum GunzipError {
    TooLarge,
    Invalid,
}

/// Decompresses a gzip body with a hard cap on the decompressed size to
/// guard against decompression bombs.
fn gunzip(data: &[u8], max_bytes: usize) -> Result<Bytes, GunzipError> {
    let mut decoder = flate2::read::GzDecoder::new(data);
    let mut out = Vec::new();
    let mut buf = [0u8; 16 * 1024];
    loop {
        let n = decoder.read(&mut buf).map_err(|_| GunzipError::Invalid)?;
        if n == 0 {
            break;
        }
        out.extend_from_slice(&buf[..n]);
        if out.len() > max_bytes {
            return Err(GunzipError::TooLarge);
        }
    }
    Ok(Bytes::from(out))
}

/// Resolves the Access-Control-Allow-Origin value for a request. `"*"` in
/// the allowlist short-circuits to a wildcard; otherwise the request origin
/// must match an entry exactly.
fn resolve_cors_origin(allowed: &[String], origin: Option<&str>) -> Option<String> {
    if allowed.iter().any(|entry| entry == "*") {
        return Some("*".to_string());
    }
    let origin = origin?;
    allowed
        .iter()
        .find(|entry| entry.as_str() == origin)
        .map(|_| origin.to_string())
}

fn apply_cors(
    mut builder: hyper::http::response::Builder,
    cors_origin: Option<String>,
) -> hyper::http::response::Builder {
    if let Some(origin) = cors_origin
        && let Ok(value) = HeaderValue::from_str(&origin)
    {
        builder = builder.header(header::ACCESS_CONTROL_ALLOW_ORIGIN, value);
    }
    builder
}

fn preflight_response(cors_origin: Option<String>) -> Response<Full<Bytes>> {
    apply_cors(
        Response::builder()
            .status(StatusCode::NO_CONTENT)
            .header(header::ACCESS_CONTROL_ALLOW_METHODS, "POST, OPTIONS")
            .header(
                header::ACCESS_CONTROL_ALLOW_HEADERS,
                "Content-Type, Content-Encoding, Authorization, X-Serviceradar-Ingestion-Key",
            )
            .header(header::ACCESS_CONTROL_MAX_AGE, "3600"),
        cors_origin,
    )
    .body(Full::new(Bytes::new()))
    .unwrap()
}

fn protobuf_response(payload: Vec<u8>, cors_origin: Option<String>) -> Response<Full<Bytes>> {
    apply_cors(
        Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, CONTENT_TYPE_PROTOBUF),
        cors_origin,
    )
    .body(Full::new(Bytes::from(payload)))
    .unwrap()
}

fn error_response(
    status: StatusCode,
    message: String,
    cors_origin: Option<String>,
) -> Response<Full<Bytes>> {
    apply_cors(
        Response::builder()
            .status(status)
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8"),
        cors_origin,
    )
    .body(Full::new(Bytes::from(message)))
    .unwrap()
}

fn decode_error_response(
    error: prost::DecodeError,
    cors_origin: Option<String>,
) -> Response<Full<Bytes>> {
    error_response(
        StatusCode::BAD_REQUEST,
        format!("failed to decode OTLP protobuf payload: {error}"),
        cors_origin,
    )
}

/// 503 with Retry-After so stock OTLP exporters back off and retransmit
/// instead of dropping the batch.
fn retryable_error_response(message: String, cors_origin: Option<String>) -> Response<Full<Bytes>> {
    apply_cors(
        Response::builder()
            .status(StatusCode::SERVICE_UNAVAILABLE)
            .header(header::RETRY_AFTER, "1")
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8"),
        cors_origin,
    )
    .body(Full::new(Bytes::from(message)))
    .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceResponse;
    use std::io::Write;

    fn test_options() -> HttpServerOptions {
        HttpServerOptions {
            addr: "127.0.0.1:0".parse().unwrap(),
            allowed_origins: vec!["*".to_string()],
            max_request_bytes: 1024 * 1024,
            tls_identity: None,
            auth: Arc::new(IngestAuth::disabled()),
        }
    }

    /// Options with token enforcement on: one token "secret-a" -> "tenant-a".
    fn test_options_with_auth() -> HttpServerOptions {
        let mut options = test_options();
        options.auth = Arc::new(
            IngestAuth::from_config(&crate::config::AuthConfig {
                enabled: true,
                tokens: vec![crate::config::AuthTokenEntry {
                    identity: "tenant-a".to_string(),
                    token: Some("secret-a".to_string()),
                    token_file: None,
                }],
            })
            .unwrap(),
        );
        options
    }

    async fn test_collector() -> ServiceRadarCollector {
        ServiceRadarCollector::new(None).await.unwrap()
    }

    fn protobuf_headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static(CONTENT_TYPE_PROTOBUF),
        );
        headers
    }

    async fn response_bytes(response: Response<Full<Bytes>>) -> Bytes {
        response.into_body().collect().await.unwrap().to_bytes()
    }

    #[tokio::test]
    async fn post_protobuf_traces_returns_ok_protobuf_response() {
        let collector = test_collector().await;
        let options = test_options();
        let body = Bytes::from(
            ExportTraceServiceRequest {
                resource_spans: vec![],
            }
            .encode_to_vec(),
        );

        let response = handle_otlp(
            &Method::POST,
            "/v1/traces",
            &protobuf_headers(),
            body,
            &options,
            &collector,
            Some("*".to_string()),
        )
        .await;

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get(header::CONTENT_TYPE).unwrap(),
            CONTENT_TYPE_PROTOBUF
        );
        assert_eq!(
            response
                .headers()
                .get(header::ACCESS_CONTROL_ALLOW_ORIGIN)
                .unwrap(),
            "*"
        );

        let payload = response_bytes(response).await;
        let decoded = ExportTraceServiceResponse::decode(payload).unwrap();
        assert!(decoded.partial_success.is_none());
    }

    #[tokio::test]
    async fn post_gzip_protobuf_traces_is_decompressed() {
        let collector = test_collector().await;
        let options = test_options();

        let raw = ExportTraceServiceRequest {
            resource_spans: vec![],
        }
        .encode_to_vec();
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(&raw).unwrap();
        let gzipped = Bytes::from(encoder.finish().unwrap());

        let mut headers = protobuf_headers();
        headers.insert(header::CONTENT_ENCODING, HeaderValue::from_static("gzip"));

        let response = handle_otlp(
            &Method::POST,
            "/v1/traces",
            &headers,
            gzipped,
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn post_json_returns_415_with_guidance() {
        let collector = test_collector().await;
        let options = test_options();

        let mut headers = HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );

        let response = handle_otlp(
            &Method::POST,
            "/v1/traces",
            &headers,
            Bytes::from_static(b"{\"resourceSpans\":[]}"),
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
        let body = String::from_utf8(response_bytes(response).await.to_vec()).unwrap();
        assert!(body.contains("OTLP/JSON is not supported"));
        assert!(body.contains("application/x-protobuf"));
    }

    #[tokio::test]
    async fn get_method_returns_405() {
        let collector = test_collector().await;
        let options = test_options();

        let response = handle_otlp(
            &Method::GET,
            "/v1/traces",
            &protobuf_headers(),
            Bytes::new(),
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
    }

    #[tokio::test]
    async fn unknown_path_returns_404() {
        let collector = test_collector().await;
        let options = test_options();

        let response = handle_otlp(
            &Method::POST,
            "/v1/profiles",
            &protobuf_headers(),
            Bytes::new(),
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn malformed_protobuf_returns_400() {
        let collector = test_collector().await;
        let options = test_options();

        let response = handle_otlp(
            &Method::POST,
            "/v1/logs",
            &protobuf_headers(),
            Bytes::from_static(&[0xff, 0xff, 0xff, 0xff]),
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn oversized_gzip_body_returns_413() {
        let collector = test_collector().await;
        let mut options = test_options();
        options.max_request_bytes = 64;

        // Compresses tiny but decompresses to 10 KiB, exceeding the cap.
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(&vec![0u8; 10 * 1024]).unwrap();
        let gzipped = Bytes::from(encoder.finish().unwrap());

        let mut headers = protobuf_headers();
        headers.insert(header::CONTENT_ENCODING, HeaderValue::from_static("gzip"));

        let response = handle_otlp(
            &Method::POST,
            "/v1/metrics",
            &headers,
            gzipped,
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }

    #[test]
    fn cors_origin_resolution() {
        let wildcard = vec!["*".to_string()];
        assert_eq!(
            resolve_cors_origin(&wildcard, Some("https://app.example.com")),
            Some("*".to_string())
        );
        assert_eq!(resolve_cors_origin(&wildcard, None), Some("*".to_string()));

        let strict = vec!["https://app.example.com".to_string()];
        assert_eq!(
            resolve_cors_origin(&strict, Some("https://app.example.com")),
            Some("https://app.example.com".to_string())
        );
        assert_eq!(
            resolve_cors_origin(&strict, Some("https://evil.example.com")),
            None
        );
        assert_eq!(resolve_cors_origin(&strict, None), None);
    }

    #[test]
    fn preflight_includes_cors_headers() {
        let response = preflight_response(Some("*".to_string()));
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
        assert_eq!(
            response
                .headers()
                .get(header::ACCESS_CONTROL_ALLOW_ORIGIN)
                .unwrap(),
            "*"
        );
        assert_eq!(
            response
                .headers()
                .get(header::ACCESS_CONTROL_ALLOW_METHODS)
                .unwrap(),
            "POST, OPTIONS"
        );
    }

    #[test]
    fn from_config_respects_enable_flag() {
        let mut config = Config::default();
        config.server.http.enabled = false;
        assert!(HttpServerOptions::from_config(&config).unwrap().is_none());

        config.server.http.enabled = true;
        let options = HttpServerOptions::from_config(&config).unwrap().unwrap();
        assert_eq!(options.addr, "0.0.0.0:4318".parse().unwrap());
        assert_eq!(options.allowed_origins, vec!["*".to_string()]);
        assert_eq!(options.max_request_bytes, 64 * 1024 * 1024);
        assert!(options.tls_identity.is_none());
    }

    #[test]
    fn from_config_skips_tls_identity_when_http_tls_disabled() {
        // tls_enabled=false must yield a plaintext listener without even
        // touching the grpc_tls cert files (paths here do not exist).
        let mut config = Config::default();
        config.server.http.tls_enabled = false;
        config.grpc_tls = Some(crate::config::GRPCTLSConfig {
            cert_file: "/nonexistent/server.pem".to_string(),
            key_file: "/nonexistent/server-key.pem".to_string(),
            ca_file: None,
            client_auth: Default::default(),
        });

        let options = HttpServerOptions::from_config(&config).unwrap().unwrap();
        assert!(options.tls_identity.is_none());
    }

    /// Minimal output backend capturing the [`IngestContext`] each publish
    /// receives, to assert HTTP-layer identity threading.
    #[derive(Default)]
    struct CaptureOutput {
        last_identity: std::sync::Mutex<Option<Option<String>>>,
    }

    impl CaptureOutput {
        fn record(&self, ctx: &IngestContext) {
            *self.last_identity.lock().unwrap() = Some(ctx.identity.clone());
        }
    }

    #[tonic::async_trait]
    impl crate::output::TelemetryOutput for CaptureOutput {
        async fn publish_traces(
            &self,
            _traces: &ExportTraceServiceRequest,
            ctx: &IngestContext,
        ) -> anyhow::Result<crate::output::PublishOutcome> {
            self.record(ctx);
            Ok(Default::default())
        }

        async fn publish_logs(
            &self,
            _logs: &ExportLogsServiceRequest,
            ctx: &IngestContext,
        ) -> anyhow::Result<crate::output::PublishOutcome> {
            self.record(ctx);
            Ok(Default::default())
        }

        async fn publish_raw_metrics(
            &self,
            _metrics: &ExportMetricsServiceRequest,
            ctx: &IngestContext,
        ) -> anyhow::Result<crate::output::PublishOutcome> {
            self.record(ctx);
            Ok(Default::default())
        }

        async fn publish_derived_metrics(
            &self,
            _metrics: &[crate::output::PerformanceMetric],
            ctx: &IngestContext,
        ) -> anyhow::Result<crate::output::PublishOutcome> {
            self.record(ctx);
            Ok(Default::default())
        }
    }

    fn empty_traces_body() -> Bytes {
        Bytes::from(
            ExportTraceServiceRequest {
                resource_spans: vec![],
            }
            .encode_to_vec(),
        )
    }

    #[tokio::test]
    async fn auth_enabled_missing_token_returns_401() {
        let collector = test_collector().await;
        let options = test_options_with_auth();

        let response = handle_otlp(
            &Method::POST,
            "/v1/traces",
            &protobuf_headers(),
            empty_traces_body(),
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let body = String::from_utf8(response_bytes(response).await.to_vec()).unwrap();
        assert!(body.contains("x-serviceradar-ingestion-key"));
    }

    #[tokio::test]
    async fn auth_enabled_invalid_token_returns_401() {
        let collector = test_collector().await;
        let options = test_options_with_auth();

        let mut headers = protobuf_headers();
        headers.insert(
            crate::auth::INGESTION_KEY_HEADER,
            HeaderValue::from_static("wrong"),
        );

        let response = handle_otlp(
            &Method::POST,
            "/v1/traces",
            &headers,
            empty_traces_body(),
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let body = String::from_utf8(response_bytes(response).await.to_vec()).unwrap();
        assert!(body.contains("invalid ingestion token"));
    }

    #[tokio::test]
    async fn auth_enabled_valid_ingestion_key_is_accepted() {
        let collector = test_collector().await;
        let options = test_options_with_auth();

        let mut headers = protobuf_headers();
        headers.insert(
            crate::auth::INGESTION_KEY_HEADER,
            HeaderValue::from_static("secret-a"),
        );

        let response = handle_otlp(
            &Method::POST,
            "/v1/traces",
            &headers,
            empty_traces_body(),
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn auth_enabled_bearer_alias_is_accepted_and_threads_identity() {
        let output = std::sync::Arc::new(CaptureOutput::default());
        let collector = ServiceRadarCollector::with_output(output.clone());
        let options = test_options_with_auth();

        let mut headers = protobuf_headers();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("Bearer secret-a"),
        );

        let response = handle_otlp(
            &Method::POST,
            "/v1/traces",
            &headers,
            empty_traces_body(),
            &options,
            &collector,
            None,
        )
        .await;

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            *output.last_identity.lock().unwrap(),
            Some(Some("tenant-a".to_string()))
        );
    }

    #[tokio::test]
    async fn auth_enabled_options_preflight_bypasses_auth() {
        let collector = test_collector().await;
        let options = test_options_with_auth();

        // No credentials at all: preflight must still succeed.
        let response = handle_otlp(
            &Method::OPTIONS,
            "/v1/traces",
            &HeaderMap::new(),
            Bytes::new(),
            &options,
            &collector,
            Some("*".to_string()),
        )
        .await;

        assert_eq!(response.status(), StatusCode::NO_CONTENT);
        assert_eq!(
            response
                .headers()
                .get(header::ACCESS_CONTROL_ALLOW_HEADERS)
                .unwrap(),
            "Content-Type, Content-Encoding, Authorization, X-Serviceradar-Ingestion-Key"
        );
    }

    #[tokio::test]
    async fn auth_disabled_allows_anonymous_and_attributes_matching_tokens() {
        let output = std::sync::Arc::new(CaptureOutput::default());
        let collector = ServiceRadarCollector::with_output(output.clone());
        // Enforcement off but a token is configured.
        let mut options = test_options_with_auth();
        options.auth = Arc::new(
            IngestAuth::from_config(&crate::config::AuthConfig {
                enabled: false,
                tokens: vec![crate::config::AuthTokenEntry {
                    identity: "tenant-a".to_string(),
                    token: Some("secret-a".to_string()),
                    token_file: None,
                }],
            })
            .unwrap(),
        );

        // Anonymous export passes with no identity.
        let response = handle_otlp(
            &Method::POST,
            "/v1/traces",
            &protobuf_headers(),
            empty_traces_body(),
            &options,
            &collector,
            None,
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(*output.last_identity.lock().unwrap(), Some(None));

        // A matching token still resolves the identity.
        let mut headers = protobuf_headers();
        headers.insert(
            crate::auth::INGESTION_KEY_HEADER,
            HeaderValue::from_static("secret-a"),
        );
        let response = handle_otlp(
            &Method::POST,
            "/v1/traces",
            &headers,
            empty_traces_body(),
            &options,
            &collector,
            None,
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            *output.last_identity.lock().unwrap(),
            Some(Some("tenant-a".to_string()))
        );
    }

    #[test]
    fn from_config_builds_auth_from_auth_section() {
        let mut config = Config::default();
        config.auth.enabled = true;
        config.auth.tokens = vec![crate::config::AuthTokenEntry {
            identity: "tenant-a".to_string(),
            token: Some("secret-a".to_string()),
            token_file: None,
        }];

        let options = HttpServerOptions::from_config(&config).unwrap().unwrap();
        assert!(options.auth.enabled());
        assert_eq!(
            options.auth.authenticate(Some("secret-a")).unwrap(),
            Some("tenant-a".to_string())
        );

        // Invalid auth config (enabled without tokens) must fail fast.
        let mut bad = Config::default();
        bad.auth.enabled = true;
        assert!(HttpServerOptions::from_config(&bad).is_err());
    }
}
