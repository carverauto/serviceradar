use anyhow::{Context, Result};
use futures::Stream;
use log::info;
use std::fs;
use std::path::PathBuf;
use std::pin::Pin;
use tonic::{
    transport::{Certificate, Identity, Server, ServerTlsConfig},
    Request, Response, Status,
};
use tonic_health::server::health_reporter;
use tonic_reflection::server::Builder as ReflectionBuilder;

use crate::config::{Config, SecurityMode};
use crate::spiffe;

pub mod monitoring {
    tonic::include_proto!("monitoring");
}
use monitoring::agent_service_server::{AgentService, AgentServiceServer};

const FILE_DESCRIPTOR_SET_MONITORING: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/monitoring_descriptor.bin"));

#[derive(Debug, Default)]
pub struct ZenAgentService;

#[tonic::async_trait]
impl AgentService for ZenAgentService {
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
            "message": "zen-consumer is operational",
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
            current_sequence: String::new(),
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

pub async fn start_grpc_server(cfg: Config) -> Result<()> {
    let addr: std::net::SocketAddr = match cfg.listen_addr.as_ref() {
        Some(addr) => addr.parse()?,
        None => return Ok(()),
    };

    match resolve_grpc_server_transport(&cfg)? {
        GrpcServerTransport::Spiffe {
            workload_socket,
            trust_domain,
        } => serve_with_spiffe(addr, &workload_socket, &trust_domain).await,
        GrpcServerTransport::Mtls {
            cert_path,
            key_path,
            ca_path,
        } => {
            let tls = build_mtls_config(cert_path, key_path, ca_path)?;
            serve_once(addr, tls).await
        }
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
        .context("grpc_security is required when listen_addr is set")?;

    match sec.mode() {
        SecurityMode::Spiffe => Ok(GrpcServerTransport::Spiffe {
            workload_socket: sec.workload_socket().to_string(),
            trust_domain: sec
                .trust_domain()
                .context("grpc_security.trust_domain is required for spiffe mode")?
                .to_string(),
        }),
        SecurityMode::Mtls => Ok(GrpcServerTransport::Mtls {
            cert_path: sec
                .cert_file_path()
                .context("grpc_security.cert_file is required for mtls mode")?,
            key_path: sec
                .key_file_path()
                .context("grpc_security.key_file is required for mtls mode")?,
            ca_path: sec
                .ca_file_path()
                .context("grpc_security.ca_file is required for mtls mode")?,
        }),
        SecurityMode::None => {
            anyhow::bail!("grpc_security.mode \"none\" is not allowed when listen_addr is set")
        }
    }
}

fn build_mtls_config(
    cert_path: PathBuf,
    key_path: PathBuf,
    ca_path: PathBuf,
) -> Result<ServerTlsConfig> {
    let cert = Identity::from_pem(fs::read(&cert_path)?, fs::read(&key_path)?);
    let ca = Certificate::from_pem(fs::read(&ca_path)?);
    Ok(ServerTlsConfig::new().identity(cert).client_ca_root(ca))
}

async fn serve_once(addr: std::net::SocketAddr, tls: ServerTlsConfig) -> Result<()> {
    let service = ZenAgentService;
    let (mut health_reporter, health_service) = health_reporter();
    health_reporter
        .set_serving::<AgentServiceServer<ZenAgentService>>()
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
        .await?;

    Ok(())
}

async fn serve_with_spiffe(
    addr: std::net::SocketAddr,
    workload_socket: &str,
    trust_domain: &str,
) -> Result<()> {
    let credentials = spiffe::load_server_credentials(workload_socket, trust_domain).await?;
    let mut updates = credentials.watch_updates();
    updates.borrow_and_update();

    loop {
        let (identity, client_ca) = credentials.tls_materials()?;

        let service = ZenAgentService;
        let (mut health_reporter, health_service) = health_reporter();
        health_reporter
            .set_serving::<AgentServiceServer<ZenAgentService>>()
            .await;

        let reflection_service = ReflectionBuilder::configure()
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
            .build_v1()?;

        let mut shutdown_rx = updates.clone();
        let tls = ServerTlsConfig::new()
            .identity(identity)
            .client_ca_root(client_ca);

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
                res?;
                return Ok(());
            }
        }

        if reload {
            info!("SPIFFE update detected; reloading zen gRPC server identity");
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
    use serde_json::json;

    fn base_config() -> Config {
        Config {
            nats_url: "nats://localhost:4222".to_string(),
            domain: None,
            stream_name: "events".to_string(),
            stream_replicas: 1,
            consumer_name: "zen-consumer".to_string(),
            subjects: vec!["logs.syslog".to_string()],
            subject_prefix: None,
            result_subject: None,
            result_subject_suffix: None,
            decision_keys: vec!["passthrough".to_string()],
            decision_groups: Vec::new(),
            discover_rules_from_kv: false,
            nats_creds_file: None,
            kv_bucket: "serviceradar-datasvc".to_string(),
            agent_id: "agent-01".to_string(),
            listen_addr: Some("0.0.0.0:50055".to_string()),
            security: None,
            grpc_security: Some(
                serde_json::from_value(json!({
                    "mode": "spiffe",
                    "trust_domain": "carverauto.dev"
                }))
                .expect("expected grpc security config"),
            ),
        }
    }

    #[test]
    fn resolve_grpc_server_transport_rejects_missing_security() {
        let mut cfg = base_config();
        cfg.grpc_security = None;

        let err = resolve_grpc_server_transport(&cfg).expect_err("expected validation error");
        assert!(
            err.to_string().contains("grpc_security is required"),
            "expected missing grpc security error, got {err}"
        );
    }

    #[test]
    fn resolve_grpc_server_transport_rejects_none_mode() {
        let mut cfg = base_config();
        cfg.grpc_security = Some(
            serde_json::from_value(json!({
                "mode": "none"
            }))
            .expect("expected grpc security config"),
        );

        let err = resolve_grpc_server_transport(&cfg).expect_err("expected validation error");
        assert!(
            err.to_string().contains("grpc_security.mode \"none\""),
            "expected insecure grpc mode error, got {err}"
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
                workload_socket: crate::config::SecurityConfig::default()
                    .workload_socket()
                    .to_string(),
                trust_domain: "carverauto.dev".to_string(),
            }
        );
    }

    #[test]
    fn resolve_grpc_server_transport_resolves_mtls_paths() {
        let mut cfg = base_config();
        cfg.grpc_security = Some(
            serde_json::from_value(json!({
                "mode": "mtls",
                "cert_dir": "/etc/serviceradar/certs",
                "tls": {
                    "cert_file": "zen.pem",
                    "key_file": "zen-key.pem",
                    "ca_file": "root.pem"
                }
            }))
            .expect("expected grpc security config"),
        );

        let transport =
            resolve_grpc_server_transport(&cfg).expect("expected mtls transport resolution");

        assert_eq!(
            transport,
            GrpcServerTransport::Mtls {
                cert_path: PathBuf::from("/etc/serviceradar/certs/zen.pem"),
                key_path: PathBuf::from("/etc/serviceradar/certs/zen-key.pem"),
                ca_path: PathBuf::from("/etc/serviceradar/certs/root.pem"),
            }
        );
    }
}
