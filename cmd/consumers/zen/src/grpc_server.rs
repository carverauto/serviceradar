use anyhow::Result;
use tonic::{
    transport::{Certificate, Identity, Server, ServerTlsConfig},
    Request, Response, Status,
};
use tonic_health::server::health_reporter;
use tonic_reflection::server::Builder as ReflectionBuilder;

use crate::config::Config;

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
        }))
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
        .build()?;

    let mut server_builder = Server::builder();
    if let Some(sec) = &cfg.grpc_security {
        if let (Some(cert), Some(key), Some(ca)) = (&sec.cert_file, &sec.key_file, &sec.ca_file) {
            let cert = std::fs::read_to_string(cert)?;
            let key = std::fs::read_to_string(key)?;
            let identity = Identity::from_pem(cert.as_bytes(), key.as_bytes());
            let ca_cert = std::fs::read_to_string(ca)?;
            let ca = Certificate::from_pem(ca_cert.as_bytes());
            let tls = ServerTlsConfig::new().identity(identity).client_ca_root(ca);
            server_builder = server_builder.tls_config(tls)?;
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