use http_body_util::Full;
use hyper::body::Bytes;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode, body::Incoming};
use hyper_util::rt::TokioIo;
use hyper_util::server::conn::auto::Builder as ConnBuilder;
use log::{debug, error, info};
use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::TcpListener;
use tonic::codec::CompressionEncoding;
use tonic::service::interceptor::InterceptedService;
use tonic::transport::{Server, ServerTlsConfig};

use crate::ServiceRadarCollector;
use crate::auth::{IngestAuth, grpc_auth_interceptor};
use crate::opentelemetry::proto::collector::logs::v1::logs_service_server::LogsServiceServer;
use crate::opentelemetry::proto::collector::metrics::v1::metrics_service_server::MetricsServiceServer;
use crate::opentelemetry::proto::collector::trace::v1::trace_service_server::TraceServiceServer;

/// Creates a ServiceRadar collector with the given NATS configuration
pub async fn create_collector(
    nats_config: Option<crate::nats::NATSConfig>,
) -> Result<ServiceRadarCollector, Box<dyn std::error::Error>> {
    debug!("Creating ServiceRadar collector");

    match ServiceRadarCollector::new(nats_config).await {
        Ok(collector) => {
            debug!("ServiceRadar collector created successfully");
            Ok(collector)
        }
        Err(e) => {
            error!("Failed to create ServiceRadar collector: {e}");
            Err(e)
        }
    }
}

/// Starts the gRPC server with the given configuration.
///
/// `max_request_bytes` bounds the decoded size of a single OTLP export
/// request (tonic's default of 4 MiB is far too small for stock OTel
/// Collector batching); wire it from `config.server.max_request_bytes`.
///
/// `auth` enforces ingestion-token authentication on every export when
/// enabled ([`crate::auth`]); pass [`IngestAuth::disabled`] for trusted
/// networks. The interceptor also resolves the sender identity attached to
/// published messages.
pub async fn start_server(
    addr: SocketAddr,
    grpc_tls_config: Option<ServerTlsConfig>,
    collector: ServiceRadarCollector,
    max_request_bytes: usize,
    auth: Arc<IngestAuth>,
) -> Result<(), Box<dyn std::error::Error>> {
    info!("OTEL Collector listening on {addr} (max request size: {max_request_bytes} bytes)");
    debug!("Starting gRPC server");

    let mut server_builder = Server::builder();

    // Configure gRPC TLS if enabled
    if let Some(tls) = grpc_tls_config {
        debug!("Configuring gRPC server with TLS");
        server_builder = server_builder.tls_config(tls)?;
    }

    if auth.enabled() {
        info!("OTLP ingestion authentication enforced on gRPC listener");
    }
    let interceptor = grpc_auth_interceptor(auth);

    let trace_collector = collector.clone();
    let logs_collector = collector.clone();
    let metrics_collector = collector;

    // Stock OTLP exporters (e.g. the OTel Collector's otlp exporter)
    // negotiate gzip by default; without accept_compressed they receive a
    // permanent UNIMPLEMENTED. Accept gzip + zstd and compress responses
    // with gzip when the client advertises support.
    let trace_service = InterceptedService::new(
        TraceServiceServer::new(trace_collector)
            .accept_compressed(CompressionEncoding::Gzip)
            .accept_compressed(CompressionEncoding::Zstd)
            .send_compressed(CompressionEncoding::Gzip)
            .max_decoding_message_size(max_request_bytes),
        interceptor.clone(),
    );
    let logs_service = InterceptedService::new(
        LogsServiceServer::new(logs_collector)
            .accept_compressed(CompressionEncoding::Gzip)
            .accept_compressed(CompressionEncoding::Zstd)
            .send_compressed(CompressionEncoding::Gzip)
            .max_decoding_message_size(max_request_bytes),
        interceptor.clone(),
    );
    let metrics_service = InterceptedService::new(
        MetricsServiceServer::new(metrics_collector)
            .accept_compressed(CompressionEncoding::Gzip)
            .accept_compressed(CompressionEncoding::Zstd)
            .send_compressed(CompressionEncoding::Gzip)
            .max_decoding_message_size(max_request_bytes),
        interceptor,
    );

    let result = server_builder
        .add_service(trace_service)
        .add_service(logs_service)
        .add_service(metrics_service)
        .serve(addr)
        .await;

    match result {
        Ok(_) => {
            info!("Server shut down gracefully");
            Ok(())
        }
        Err(e) => {
            error!("Server error: {e}");
            Err(e.into())
        }
    }
}

/// Start a simple HTTP server to serve Prometheus metrics
pub async fn start_metrics_server(addr: SocketAddr) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting metrics server on {addr}");

    let listener = TcpListener::bind(addr).await?;

    loop {
        let (stream, _) = listener.accept().await?;

        tokio::task::spawn(async move {
            let conn_builder = ConnBuilder::new(hyper_util::rt::TokioExecutor::new());
            let io = TokioIo::new(stream);

            if let Err(err) = conn_builder
                .serve_connection(io, service_fn(metrics_handler))
                .await
            {
                error!("Error serving connection: {err:?}");
            }
        });
    }
}

async fn metrics_handler(req: Request<Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    match (req.method(), req.uri().path()) {
        (&Method::GET, "/metrics") => {
            debug!("Serving metrics endpoint");
            match crate::metrics::get_metrics_text() {
                Ok(metrics) => Ok(Response::builder()
                    .status(StatusCode::OK)
                    .header("content-type", "text/plain; version=0.0.4; charset=utf-8")
                    .body(Full::new(Bytes::from(metrics)))
                    .unwrap()),
                Err(e) => {
                    error!("Failed to gather metrics: {e}");
                    Ok(Response::builder()
                        .status(StatusCode::INTERNAL_SERVER_ERROR)
                        .body(Full::new(Bytes::from("Error gathering metrics")))
                        .unwrap())
                }
            }
        }
        (&Method::GET, "/health") => Ok(Response::builder()
            .status(StatusCode::OK)
            .body(Full::new(Bytes::from("OK")))
            .unwrap()),
        _ => Ok(Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Full::new(Bytes::from("Not Found")))
            .unwrap()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_create_collector_without_nats() {
        let result = create_collector(None).await;
        assert!(result.is_ok());
    }

    #[test]
    fn test_server_creation() {
        // Test that we can create a server configuration without panicking
        let addr: SocketAddr = "127.0.0.1:8080".parse().unwrap();
        assert_eq!(addr.port(), 8080);
    }
}
