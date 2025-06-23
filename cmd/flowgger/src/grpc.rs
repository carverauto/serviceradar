use anyhow::Result;
use serde_json::Value;
use tonic::{
    transport::{Certificate, Identity, Server, ServerTlsConfig},
    Request, Response, Status,
};
use tonic_health::server::health_reporter;
use tonic_reflection::server::Builder as ReflectionBuilder;

pub mod monitoring {
    tonic::include_proto!("monitoring");
}
use monitoring::agent_service_server::{AgentService, AgentServiceServer};

const FILE_DESCRIPTOR_SET_MONITORING: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/monitoring_descriptor.bin"));

#[derive(Default)]
struct FlowggerAgentService;

#[tonic::async_trait]
impl AgentService for FlowggerAgentService {
    async fn get_status(
        &self,
        request: Request<monitoring::StatusRequest>,
    ) -> Result<Response<monitoring::StatusResponse>, Status> {
        let req = request.into_inner();
        let start = std::time::Instant::now();
        let mut obj = serde_json::Map::new();
        obj.insert("status".to_string(), Value::String("operational".into()));
        obj.insert(
            "message".to_string(),
            Value::String("flowgger is operational".into()),
        );
        let data = serde_json::to_vec(&Value::Object(obj)).unwrap_or_default();
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
}

pub struct GrpcConfig {
    pub listen_addr: String,
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
}

async fn run_server(cfg: GrpcConfig) -> Result<()> {
    let addr: std::net::SocketAddr = cfg.listen_addr.parse()?;
    let service = FlowggerAgentService::default();
    let (mut health_reporter, health_service) = health_reporter();
    health_reporter
        .set_serving::<AgentServiceServer<FlowggerAgentService>>()
        .await;

    let reflection_service = ReflectionBuilder::configure()
        .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
        .build()?;

    let mut server_builder = Server::builder();
    if let (Some(cert), Some(key), Some(ca)) = (cfg.cert_file, cfg.key_file, cfg.ca_file) {
        let cert = std::fs::read_to_string(cert)?;
        let key = std::fs::read_to_string(key)?;
        let identity = Identity::from_pem(cert.as_bytes(), key.as_bytes());
        let ca_cert = std::fs::read_to_string(ca)?;
        let ca = Certificate::from_pem(ca_cert.as_bytes());
        let tls = ServerTlsConfig::new().identity(identity).client_ca_root(ca);
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

pub fn spawn_server(cfg: GrpcConfig) {
    std::thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        if let Err(e) = rt.block_on(run_server(cfg)) {
            eprintln!("gRPC server error: {e}");
        }
    });
}
