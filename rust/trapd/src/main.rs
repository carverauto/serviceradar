/*
 * Copyright 2025 Carver Automation Corporation.
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

use anyhow::{Context, Result};
use clap::Parser;
use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat};
use env_logger::Env;
use futures::Stream;
use log::{info, warn};
use serde::Serialize;
use std::pin::Pin;
use std::sync::Once;
use std::{fs, net::SocketAddr, path::PathBuf};
use tokio::net::UdpSocket;

use tonic::{
    transport::{Certificate, Identity, Server, ServerTlsConfig},
    Request, Response, Status,
};
use tonic_health::server::health_reporter;
use tonic_reflection::server::Builder as ReflectionBuilder;

mod config;
mod spiffe;
use config::{Config, SecurityMode};

pub mod monitoring {
    tonic::include_proto!("monitoring");
}
use monitoring::agent_service_server::{AgentService, AgentServiceServer};

const FILE_DESCRIPTOR_SET_MONITORING: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/monitoring_descriptor.bin"));
const DEFAULT_WORKLOAD_SOCKET: &str = "unix:/run/spire/sockets/agent.sock";

#[derive(Parser, Debug)]
#[command(name = "serviceradar-trapd")]
#[command(about = "ServiceRadar SNMP Trap Receiver", long_about = None)]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, env = "TRAPD_CONFIG")]
    config: Option<String>,
}

#[derive(Serialize)]
struct Varbind {
    oid: String,
    value: String,
}

#[derive(Serialize)]
struct TrapMessage {
    source: String,
    version: String,
    community: String,
    varbinds: Vec<Varbind>,
}

#[tokio::main]
async fn main() -> Result<()> {
    ensure_rustls_provider_installed();
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();

    let cli = Cli::parse();
    let config_path = cli
        .config
        .clone()
        .unwrap_or_else(|| "/etc/serviceradar/trapd.json".to_string());
    let pinned_path = config_bootstrap::pinned_path_from_env();
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "trapd".to_string(),
        config_path: config_path.clone(),
        format: ConfigFormat::Json,
        pinned_path: pinned_path.clone(),
    })
    .await?;
    let cfg: Config = bootstrap.load().await?;
    cfg.validate()?;

    info!("Starting trap receiver on {}", cfg.listen_addr);

    if cfg.grpc_listen_addr.is_some() {
        let grpc_cfg = cfg.clone();
        tokio::spawn(async move {
            if let Err(e) = start_grpc_server(grpc_cfg).await {
                warn!("gRPC server error: {e:#}");
            }
        });
    }

    let socket = UdpSocket::bind(&cfg.listen_addr).await?;

    let creds_path = cfg.nats_creds_path();
    let nats_client = if let Some(sec) = &cfg.nats_security {
        match sec.mode {
            SecurityMode::None => {
                if let Some(creds_path) = &creds_path {
                    async_nats::ConnectOptions::new()
                        .credentials_file(creds_path)
                        .await?
                        .connect(&cfg.nats_url)
                        .await?
                } else {
                    async_nats::connect(&cfg.nats_url).await?
                }
            }
            SecurityMode::Spiffe => {
                anyhow::bail!("SPIFFE mode is not supported for NATS security")
            }
            SecurityMode::Mtls => {
                let mut opts = async_nats::ConnectOptions::new();
                if let Some(creds_path) = &creds_path {
                    opts = opts.credentials_file(creds_path).await?;
                }
                if let Some(ca) = &sec.ca_file {
                    opts = opts.add_root_certificates(sec.resolve_path(ca));
                }
                if let (Some(cert), Some(key)) = (&sec.cert_file, &sec.key_file) {
                    opts =
                        opts.add_client_certificate(sec.resolve_path(cert), sec.resolve_path(key));
                }
                opts.connect(&cfg.nats_url).await?
            }
        }
    } else if let Some(creds_path) = &creds_path {
        async_nats::ConnectOptions::new()
            .credentials_file(creds_path)
            .await?
            .connect(&cfg.nats_url)
            .await?
    } else {
        async_nats::connect(&cfg.nats_url).await?
    };
    let js = if let Some(domain) = &cfg.nats_domain {
        async_nats::jetstream::with_domain(nats_client, domain)
    } else {
        async_nats::jetstream::new(nats_client)
    };

    if let Err(e) = ensure_stream(&js, &cfg).await {
        warn!("failed to ensure stream {}: {e}", cfg.stream_name);
    }

    let mut buf = vec![0u8; 65535];
    loop {
        let (len, addr) = socket.recv_from(&mut buf).await?;
        let data = &buf[..len];
        match snmp2::Pdu::from_bytes(data) {
            Ok(pdu) => {
                let msg = build_message(&pdu, addr);
                let payload = serde_json::to_vec(&msg)?;
                if let Err(e) = js.publish(cfg.subject.clone(), payload.into()).await?.await {
                    warn!("Failed to publish trap: {e}");
                }
            }
            Err(e) => {
                warn!("Failed to parse SNMP trap from {addr}: {e}");
            }
        }
    }
}

fn ensure_rustls_provider_installed() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    });
}

async fn ensure_stream(js: &async_nats::jetstream::Context, cfg: &Config) -> Result<()> {
    match js.get_stream(&cfg.stream_name).await {
        Ok(mut stream) => {
            let info = stream.info().await?;
            let mut updated_config = info.config.clone();
            let mut changed = false;

            if !updated_config.subjects.contains(&cfg.subject) {
                updated_config.subjects.push(cfg.subject.clone());
                changed = true;
            }
            if updated_config.num_replicas != cfg.stream_replicas {
                updated_config.num_replicas = cfg.stream_replicas;
                changed = true;
            }

            if changed {
                js.update_stream(updated_config).await?;
            }
        }
        Err(_) => {
            let stream_config = async_nats::jetstream::stream::Config {
                name: cfg.stream_name.clone(),
                subjects: vec![cfg.subject.clone()],
                storage: async_nats::jetstream::stream::StorageType::File,
                num_replicas: cfg.stream_replicas,
                ..Default::default()
            };
            js.get_or_create_stream(stream_config).await?;
        }
    }

    Ok(())
}

fn build_message(pdu: &snmp2::Pdu<'_>, addr: SocketAddr) -> TrapMessage {
    let version = match pdu.version() {
        Ok(v) => format!("{v:?}"),
        Err(_) => "unknown".to_string(),
    };
    let community = String::from_utf8_lossy(pdu.community).into_owned();
    let mut varbinds = Vec::new();
    for (oid, value) in pdu.varbinds.clone() {
        varbinds.push(Varbind {
            oid: format!("{oid}"),
            value: format!("{value:?}"),
        });
    }
    TrapMessage {
        source: addr.to_string(),
        version,
        community,
        varbinds,
    }
}

#[derive(Debug, Default)]
struct TrapdAgentService;

#[tonic::async_trait]
impl AgentService for TrapdAgentService {
    type StreamResultsStream =
        Pin<Box<dyn Stream<Item = Result<monitoring::ResultsChunk, Status>> + Send + 'static>>;
    async fn get_status(
        &self,
        request: Request<monitoring::StatusRequest>,
    ) -> Result<Response<monitoring::StatusResponse>, Status> {
        let req = request.into_inner();
        let start = std::time::Instant::now();
        let msg = serde_json::json!({
            "status": "operational",
            "message": "trapd is operational",
        });
        let data = serde_json::to_vec(&msg).unwrap_or_default();
        Ok(Response::new(monitoring::StatusResponse {
            available: true,
            message: data,
            service_name: req.service_name,
            service_type: req.service_type,
            response_time: start.elapsed().as_nanos() as i64,
            agent_id: req.agent_id,
            gateway_id: req.gateway_id,
        }))
    }

    async fn get_results(
        &self,
        request: Request<monitoring::ResultsRequest>,
    ) -> Result<Response<monitoring::ResultsResponse>, Status> {
        let req = request.into_inner();
        let start = std::time::Instant::now();
        Ok(Response::new(monitoring::ResultsResponse {
            available: true,
            data: vec![],
            service_name: req.service_name,
            service_type: req.service_type,
            response_time: start.elapsed().as_nanos() as i64,
            agent_id: req.agent_id,
            gateway_id: req.gateway_id,
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64,
            current_sequence: "1".to_string(),
            has_new_data: false,
            sweep_completion: None,
            execution_id: String::new(),
            sweep_group_id: String::new(),
        }))
    }

    async fn stream_results(
        &self,
        request: Request<monitoring::ResultsRequest>,
    ) -> Result<Response<Self::StreamResultsStream>, Status> {
        let _req = request.into_inner();

        // Create an empty stream for now - in a real implementation this would
        // stream actual results data in chunks
        let stream = futures::stream::empty();

        Ok(Response::new(Box::pin(stream)))
    }
}

async fn start_grpc_server(cfg: Config) -> Result<()> {
    let addr: std::net::SocketAddr = match cfg.grpc_listen_addr {
        Some(ref a) => a.parse()?,
        None => return Ok(()),
    };

    match resolve_grpc_server_transport(&cfg)? {
        GrpcServerTransport::Mtls {
            cert_path,
            key_path,
            ca_path,
        } => {
            let cert = fs::read(&cert_path)?;
            let key = fs::read(&key_path)?;
            let identity = Identity::from_pem(cert, key);
            let ca = Certificate::from_pem(fs::read(&ca_path)?);
            let tls = ServerTlsConfig::new().identity(identity).client_ca_root(ca);
            serve_with_tls(addr, tls).await
        }
        GrpcServerTransport::Spiffe {
            workload_socket,
            trust_domain,
        } => serve_with_spiffe(addr, &workload_socket, &trust_domain).await,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum GrpcServerTransport {
    Mtls {
        cert_path: PathBuf,
        key_path: PathBuf,
        ca_path: PathBuf,
    },
    Spiffe {
        workload_socket: String,
        trust_domain: String,
    },
}

fn resolve_grpc_server_transport(cfg: &Config) -> Result<GrpcServerTransport> {
    let sec = cfg
        .grpc_security
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("grpc_security is required when grpc_listen_addr is set"))?;

    match sec.mode {
        SecurityMode::None => {
            anyhow::bail!("grpc_security.mode \"none\" is not allowed when grpc_listen_addr is set")
        }
        SecurityMode::Mtls => Ok(GrpcServerTransport::Mtls {
            cert_path: sec
                .cert_file
                .as_ref()
                .map(|p| sec.resolve_path(p))
                .ok_or_else(|| anyhow::anyhow!("missing trapd gRPC cert_file"))?,
            key_path: sec
                .key_file
                .as_ref()
                .map(|p| sec.resolve_path(p))
                .ok_or_else(|| anyhow::anyhow!("missing trapd gRPC key_file"))?,
            ca_path: sec
                .client_ca_path()
                .ok_or_else(|| anyhow::anyhow!("missing trapd gRPC client_ca_file or ca_file"))?,
        }),
        SecurityMode::Spiffe => Ok(GrpcServerTransport::Spiffe {
            workload_socket: sec
                .workload_socket
                .as_deref()
                .filter(|s| !s.trim().is_empty())
                .unwrap_or(DEFAULT_WORKLOAD_SOCKET)
                .to_string(),
            trust_domain: sec
                .trust_domain
                .clone()
                .ok_or_else(|| anyhow::anyhow!("missing trapd gRPC trust_domain"))?,
        }),
    }
}

async fn serve_with_tls(addr: SocketAddr, tls: ServerTlsConfig) -> Result<()> {
    let service = TrapdAgentService;
    let (mut health_reporter, health_service) = health_reporter();
    health_reporter
        .set_serving::<AgentServiceServer<TrapdAgentService>>()
        .await;

    let reflection_service = ReflectionBuilder::configure()
        .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
        .build_v1()?;

    Server::builder()
        .tls_config(tls)?
        .add_service(health_service)
        .add_service(AgentServiceServer::new(service))
        .add_service(reflection_service)
        .serve(addr)
        .await
        .context("trapd gRPC server failed")
}

async fn serve_with_spiffe(
    addr: SocketAddr,
    workload_socket: &str,
    trust_domain: &str,
) -> Result<()> {
    let credentials = spiffe::load_server_credentials(workload_socket, trust_domain)
        .await
        .context("failed to load SPIFFE credentials for trapd gRPC server")?;
    let mut updates = credentials.watch_updates();
    updates.borrow_and_update();

    loop {
        let service = TrapdAgentService;
        let (mut health_reporter, health_service) = health_reporter();
        health_reporter
            .set_serving::<AgentServiceServer<TrapdAgentService>>()
            .await;

        let reflection_service = ReflectionBuilder::configure()
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
            .build_v1()?;

        let (identity, client_ca) = credentials.tls_materials()?;
        let tls = ServerTlsConfig::new()
            .identity(identity)
            .client_ca_root(client_ca);

        let mut shutdown_rx = updates.clone();
        let server_future = Server::builder()
            .tls_config(tls)?
            .add_service(health_service)
            .add_service(AgentServiceServer::new(service))
            .add_service(reflection_service)
            .serve_with_shutdown(addr, async move {
                let _ = shutdown_rx.changed().await;
            });

        tokio::pin!(server_future);

        let mut reload = false;
        let mut channel_closed = false;

        tokio::select! {
            biased;
            res = updates.changed() => {
                match res {
                    Ok(_) => reload = true,
                    Err(_) => channel_closed = true,
                }
            }
            res = &mut server_future => {
                res.context("trapd gRPC server encountered an error during SPIFFE serve")?;
                return Ok(());
            }
        }

        if reload {
            info!("SPIFFE update detected; reloading trapd gRPC server identity");
            updates.borrow_and_update();
            server_future.await?;
            continue;
        }

        if channel_closed {
            server_future.await?;
            break;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::SecurityConfig;
    use std::path::Path;

    fn base_config() -> Config {
        Config {
            listen_addr: "0.0.0.0:162".into(),
            nats_url: "tls://serviceradar-nats:4222".into(),
            nats_domain: None,
            stream_name: "events".into(),
            subject: "logs.snmp".into(),
            nats_creds_file: None,
            nats_security: None,
            grpc_listen_addr: Some("0.0.0.0:50043".into()),
            grpc_security: Some(SecurityConfig {
                mode: SecurityMode::Spiffe,
                trust_domain: Some("carverauto.dev".into()),
                workload_socket: None,
                ..Default::default()
            }),
        }
    }

    #[test]
    fn resolve_grpc_server_transport_rejects_none_mode() {
        let mut cfg = base_config();
        if let Some(sec) = cfg.grpc_security.as_mut() {
            sec.mode = SecurityMode::None;
        }

        let err = resolve_grpc_server_transport(&cfg).expect_err("expected validation error");
        assert!(
            err.to_string().contains("grpc_security.mode \"none\""),
            "expected none-mode error, got {err}"
        );
    }

    #[test]
    fn resolve_grpc_server_transport_defaults_spiffe_socket() {
        let cfg = base_config();

        let transport =
            resolve_grpc_server_transport(&cfg).expect("expected spiffe transport resolution");

        assert_eq!(
            transport,
            GrpcServerTransport::Spiffe {
                workload_socket: DEFAULT_WORKLOAD_SOCKET.to_string(),
                trust_domain: "carverauto.dev".to_string(),
            }
        );
    }

    #[test]
    fn resolve_grpc_server_transport_resolves_mtls_paths() {
        let mut cfg = base_config();
        cfg.grpc_security = Some(SecurityConfig {
            mode: SecurityMode::Mtls,
            cert_dir: Some("/etc/serviceradar/certs".into()),
            cert_file: Some("trapd.pem".into()),
            key_file: Some("trapd-key.pem".into()),
            ca_file: Some("root.pem".into()),
            client_ca_file: Some("client-root.pem".into()),
            ..Default::default()
        });

        let transport =
            resolve_grpc_server_transport(&cfg).expect("expected mtls transport resolution");

        assert_eq!(
            transport,
            GrpcServerTransport::Mtls {
                cert_path: Path::new("/etc/serviceradar/certs/trapd.pem").to_path_buf(),
                key_path: Path::new("/etc/serviceradar/certs/trapd-key.pem").to_path_buf(),
                ca_path: Path::new("/etc/serviceradar/certs/client-root.pem").to_path_buf(),
            }
        );
    }
}
