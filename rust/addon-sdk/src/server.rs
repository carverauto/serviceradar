/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Wires the [`Addon`](crate::Addon) trait to the go-plugin transport: the
//! handshake, AutoMTLS, the gRPC `AddonService`, and the gRPC health service the
//! agent's go-plugin client pings (`grpc.health.v1.Health/Check` for the service
//! named `plugin`, i.e. `GRPCServiceName`).

use std::sync::Arc;

use tokio::net::UnixListener;
use tokio_stream::StreamExt as _;
use tokio_stream::wrappers::UnixListenerStream;
use tonic::transport::Server;
use tonic::{Request, Response, Status, Streaming};

use crate::handshake::{self, HandshakeError};
use crate::pb::addon_service_server::{AddonService, AddonServiceServer};
use crate::pb::{
    ConfigureRequest, ConfigureResponse, HealthRequest, HealthResponse, InfoRequest, InfoResponse,
    MetricFeedFrame, OtlpRelayAck, RunCommandRequest, RunCommandResponse, StreamTelemetryRequest,
};
use crate::tls::{self, MtlsError};
use crate::{
    Addon, CommandRequest, MetricFeedAckStream, MetricFeedStream, OtlpRelayAckStream,
    OtlpRelayStream, TelemetryStream,
};

/// The gRPC health-check service name the go-plugin client probes
/// (`go-plugin`'s `GRPCServiceName`). The agent calls `Health/Check` for this
/// name to confirm the plugin is up before dispensing.
const GRPC_SERVICE_NAME: &str = "plugin";

/// Errors raised while serving an add-on.
#[derive(Debug, thiserror::Error)]
pub enum ServeError {
    #[error(transparent)]
    Handshake(#[from] HandshakeError),
    #[error(transparent)]
    Mtls(#[from] MtlsError),
    #[error("failed to emit handshake line: {0}")]
    Stdout(std::io::Error),
    #[error("gRPC transport error: {0}")]
    Transport(#[from] tonic::transport::Error),
}

/// Serves `addon` over the go-plugin transport until the host terminates the
/// process (or SIGINT/SIGTERM). This is the Rust analogue of the Go SDK's
/// `sdk.Serve`.
///
/// Steps, in go-plugin order:
/// 1. verify the magic cookie,
/// 2. bind the host-restricted Unix-domain socket,
/// 3. set up AutoMTLS from `PLUGIN_CLIENT_CERT` (if present),
/// 4. print the handshake line to stdout and flush,
/// 5. serve `AddonService` + the gRPC health service.
///
/// On any pre-serve error this returns `Err`; the reference binary maps that to
/// the same exit-1 / friendly-message behavior a Go add-on has.
pub async fn serve<A: Addon>(addon: A) -> Result<(), ServeError> {
    // Install the default rustls crypto provider (ring) once, so tonic's TLS
    // acceptor can build a ServerConfig. Ignored if already installed.
    let _ = rustls::crypto::ring::default_provider().install_default();

    handshake::check_magic_cookie()?;

    let listener = handshake::bind_plugin_socket()?;
    let socket_path = listener.path.clone();

    // AutoMTLS: present only when the host launched us with a client cert.
    let client_cert = std::env::var(handshake::ENV_CLIENT_CERT).unwrap_or_default();
    let tls_config = if client_cert.is_empty() {
        None
    } else {
        Some(tls::build_server_mtls(&client_cert)?)
    };

    let server_cert_b64 = tls_config
        .as_ref()
        .map(|m| m.server_cert_b64.clone())
        .unwrap_or_default();

    // Emit the handshake line the host parses to learn (addr, cert).
    let line = handshake::build_handshake_line(&socket_path, &server_cert_b64);
    handshake::emit_handshake_line(&line).map_err(ServeError::Stdout)?;

    serve_on_listener(addon, listener.listener, tls_config).await
}

/// Serves on an already-bound listener with an optional AutoMTLS config. Split
/// out so integration tests can drive the transport directly.
pub async fn serve_on_listener<A: Addon>(
    addon: A,
    listener: UnixListener,
    tls_config: Option<tls::ServerMtls>,
) -> Result<(), ServeError> {
    let inner: Arc<dyn Addon> = Arc::new(addon);
    let service = AddonServiceServer::new(AddonGrpc {
        inner: inner.clone(),
    });

    // The go-plugin client confirms liveness via grpc.health.v1.Health/Check for
    // the "plugin" service before dispensing. Report SERVING for that name.
    let (health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_service_status(GRPC_SERVICE_NAME, tonic_health::ServingStatus::Serving)
        .await;

    let router = Server::builder()
        .add_service(health_service)
        .add_service(service);

    match tls_config {
        // AutoMTLS: TLS-wrap each accepted Unix connection ourselves with a
        // hand-built rustls ServerConfig (see crate::tls for why tonic's
        // ServerTlsConfig/WebPkiClientVerifier is unsuitable for go-plugin's
        // self-signed-CA client certs), then feed the TLS streams to tonic.
        Some(mtls) => {
            let server_config = mtls.server_config()?;
            let acceptor = tokio_rustls::TlsAcceptor::from(server_config);

            // An accept task TLS-handshakes each Unix connection and forwards the
            // completed stream over a channel; tonic consumes the channel as its
            // incoming connection stream. Each handshake runs in its own task so
            // a slow or failed handshake never blocks accepting new connections,
            // and a failed handshake just drops that connection.
            let (tx, rx) = tokio::sync::mpsc::channel::<
                Result<tokio_rustls::server::TlsStream<tokio::net::UnixStream>, std::io::Error>,
            >(32);
            tokio::spawn(async move {
                let mut unix = UnixListenerStream::new(listener);
                while let Some(conn) = unix.next().await {
                    let stream = match conn {
                        Ok(s) => s,
                        Err(_) => continue,
                    };
                    let acceptor = acceptor.clone();
                    let tx = tx.clone();
                    tokio::spawn(async move {
                        if let Ok(tls) = acceptor.accept(stream).await {
                            let _ = tx.send(Ok(tls)).await;
                        }
                    });
                }
            });

            let incoming = tokio_stream::wrappers::ReceiverStream::new(rx);
            router
                .serve_with_incoming_shutdown(incoming, shutdown_signal(inner.clone()))
                .await?;
        }
        // No AutoMTLS (host launched without PLUGIN_CLIENT_CERT): serve plaintext
        // gRPC over the Unix socket, which the host restricts by directory.
        None => {
            let incoming = UnixListenerStream::new(listener);
            router
                .serve_with_incoming_shutdown(incoming, shutdown_signal(inner.clone()))
                .await?;
        }
    }

    Ok(())
}

/// Resolves when the process receives SIGINT or SIGTERM. go-plugin clients kill
/// plugins with a signal on shutdown; we stop the server gracefully so the
/// Unix-domain socket is cleaned up.
async fn shutdown_signal(addon: Arc<dyn Addon>) {
    use tokio::signal::unix::{SignalKind, signal};
    let mut sigint = signal(SignalKind::interrupt()).expect("install SIGINT handler");
    let mut sigterm = signal(SignalKind::terminate()).expect("install SIGTERM handler");
    tokio::select! {
        _ = sigint.recv() => {}
        _ = sigterm.recv() => {}
    }

    let _ = addon.shutdown().await;
}

/// Adapts an [`Addon`] to the generated `AddonService` gRPC server.
struct AddonGrpc {
    inner: Arc<dyn Addon>,
}

#[tonic::async_trait]
impl AddonService for AddonGrpc {
    type StreamTelemetryStream = TelemetryStream;

    async fn info(&self, _request: Request<InfoRequest>) -> Result<Response<InfoResponse>, Status> {
        let info = self
            .inner
            .info()
            .await
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(InfoResponse {
            id: info.id,
            version: info.version,
            capabilities: info.capabilities,
        }))
    }

    async fn configure(
        &self,
        request: Request<ConfigureRequest>,
    ) -> Result<Response<ConfigureResponse>, Status> {
        let config_json = request.into_inner().config_json;
        let result = self
            .inner
            .configure(&config_json)
            .await
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(ConfigureResponse {
            config_hash: result.config_hash,
            accepted: result.accepted,
            error: result.error,
        }))
    }

    async fn health(
        &self,
        _request: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        let health = self
            .inner
            .health()
            .await
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(HealthResponse {
            status: health.status.to_proto() as i32,
            version: health.version,
            degradation_reason: health.degradation_reason,
            details: health.details.into_iter().collect(),
        }))
    }

    async fn stream_telemetry(
        &self,
        _request: Request<StreamTelemetryRequest>,
    ) -> Result<Response<Self::StreamTelemetryStream>, Status> {
        Ok(Response::new(self.inner.stream_telemetry()))
    }

    type RelayOtlpStream = OtlpRelayStream;

    async fn run_command(
        &self,
        request: Request<RunCommandRequest>,
    ) -> Result<Response<RunCommandResponse>, Status> {
        let request = request.into_inner();
        let result = self
            .inner
            .run_command(CommandRequest {
                command_id: request.command_id,
                command_type: request.command_type,
                action_id: request.action_id,
                schema: request.schema,
                payload_json: request.payload_json,
                deadline_unix: request.deadline_unix,
                metadata: request.metadata,
            })
            .await
            .map_err(|e| Status::internal(e.to_string()))?;

        Ok(Response::new(RunCommandResponse {
            success: result.success,
            message: result.message,
            payload_json: result.payload_json,
            metadata: result.metadata,
        }))
    }

    async fn relay_otlp(
        &self,
        request: Request<Streaming<OtlpRelayAck>>,
    ) -> Result<Response<Self::RelayOtlpStream>, Status> {
        // Box tonic's request stream into the transport-agnostic alias the
        // Addon trait consumes; the default implementation rejects the call
        // with UNIMPLEMENTED for add-ons without otlp-relay:v1.
        let acks: OtlpRelayAckStream = Box::pin(request.into_inner());
        Ok(Response::new(self.inner.relay_otlp(acks)?))
    }

    type StreamMetricFeedStream = MetricFeedAckStream;

    async fn stream_metric_feed(
        &self,
        request: Request<Streaming<MetricFeedFrame>>,
    ) -> Result<Response<Self::StreamMetricFeedStream>, Status> {
        // Box tonic's inbound frame stream into the transport-agnostic alias the
        // Addon trait consumes; the default implementation rejects the call with
        // UNIMPLEMENTED for add-ons without metric-feed:v1.
        let frames: MetricFeedStream = Box::pin(request.into_inner());
        Ok(Response::new(self.inner.stream_metric_feed(frames)?))
    }
}
