use anyhow::{Context, Result};
use futures::Stream;
use std::fs;
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
    let service = ZenAgentService;
    let (mut health_reporter, health_service) = health_reporter();
    health_reporter
        .set_serving::<AgentServiceServer<ZenAgentService>>()
        .await;

    let reflection_service = ReflectionBuilder::configure()
        .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
        .build_v1()?;

    let mut server_builder = Server::builder();
    let mut _spiffe_guard: Option<spiffe::SpiffeSourceGuard> = None;
    if let Some(sec) = &cfg.grpc_security {
        match sec.mode() {
            SecurityMode::Spiffe => {
                let trust_domain = sec
                    .trust_domain()
                    .context("grpc_security.trust_domain is required for spiffe mode")?;
                let credentials =
                    spiffe::load_server_credentials(sec.workload_socket(), trust_domain).await?;
                let (identity, client_ca, guard) = credentials.into_parts();
                let tls = ServerTlsConfig::new()
                    .identity(identity)
                    .client_ca_root(client_ca);
                _spiffe_guard = Some(guard);
                server_builder = server_builder.tls_config(tls)?;
            }
            SecurityMode::Mtls => {
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
                let tls = ServerTlsConfig::new().identity(cert).client_ca_root(ca);
                server_builder = server_builder.tls_config(tls)?;
            }
            SecurityMode::None => {}
        }
    }

    server_builder
        .add_service(health_service)
        .add_service(AgentServiceServer::new(service))
        .add_service(reflection_service)
        .serve(addr)
        .await?;

    Ok(())
}
