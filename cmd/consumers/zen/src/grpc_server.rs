use anyhow::{Context, Result};
use futures::Stream;
use log::info;
use std::fs;
use std::pin::Pin;
use tonic::{
    transport::{Certificate, Identity, Server, ServerTlsConfig},
    Request, Response, Status,
};
use tonic_health::server::health_reporter;
use tonic_reflection::server::Builder as ReflectionBuilder;

use crate::config::{Config, SecurityConfig, SecurityMode};
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
            poller_id: req.poller_id,
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
            poller_id: req.poller_id,
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64,
            current_sequence: String::new(),
            has_new_data: false,
            sweep_completion: None,
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
    let addr: std::net::SocketAddr = cfg.listen_addr.parse()?;

    match cfg.grpc_security.as_ref().map(|sec| sec.mode()) {
        Some(SecurityMode::Spiffe) => {
            serve_with_spiffe(addr, cfg.grpc_security.as_ref().unwrap()).await
        }
        Some(SecurityMode::Mtls) => {
            let tls = build_mtls_config(cfg.grpc_security.as_ref().unwrap())?;
            serve_once(addr, Some(tls)).await
        }
        Some(SecurityMode::None) | None => serve_once(addr, None).await,
    }
}

fn build_mtls_config(sec: &SecurityConfig) -> Result<ServerTlsConfig> {
    let cert_path = sec
        .cert_file_path()
        .context("grpc_security.cert_file is required for mtls mode")?;
    let key_path = sec
        .key_file_path()
        .context("grpc_security.key_file is required for mtls mode")?;
    let ca_path = sec
        .ca_file_path()
        .context("grpc_security.ca_file is required for mtls mode")?;

    let cert = Identity::from_pem(fs::read(&cert_path)?, fs::read(&key_path)?);
    let ca = Certificate::from_pem(fs::read(&ca_path)?);
    Ok(ServerTlsConfig::new().identity(cert).client_ca_root(ca))
}

async fn serve_once(addr: std::net::SocketAddr, tls: Option<ServerTlsConfig>) -> Result<()> {
    let service = ZenAgentService;
    let (mut health_reporter, health_service) = health_reporter();
    health_reporter
        .set_serving::<AgentServiceServer<ZenAgentService>>()
        .await;

    let reflection_service = ReflectionBuilder::configure()
        .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
        .build_v1()?;

    let mut server_builder = Server::builder();
    if let Some(tls) = tls {
        server_builder = server_builder.tls_config(tls)?;
    }

    server_builder
        .add_service(health_service)
        .add_service(AgentServiceServer::new(service))
        .add_service(reflection_service)
        .serve(addr)
        .await?;

    Ok(())
}

async fn serve_with_spiffe(addr: std::net::SocketAddr, sec: &SecurityConfig) -> Result<()> {
    let trust_domain = sec
        .trust_domain()
        .context("grpc_security.trust_domain is required for spiffe mode")?;
    let credentials = spiffe::load_server_credentials(sec.workload_socket(), trust_domain).await?;
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
