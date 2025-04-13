use std::fs;
use anyhow::{Context, Result};
use log::{debug, info};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::task::JoinHandle;
use tonic::{Request, Response, Status};
use tonic::transport::Server;
use tonic_reflection::server::Builder as ReflectionBuilder;
use tokio::sync::RwLock;

use crate::config::Config;
use crate::poller::MetricsCollector;
use crate::server::monitoring::agent_service_server::{AgentService, AgentServiceServer};

const FILE_DESCRIPTOR_SET_MONITORING: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/monitoring_descriptor.bin"));

pub mod monitoring {
    tonic::include_proto!("monitoring");
}

#[derive(Debug)]
pub struct SysmonService {
    collector: Arc<RwLock<MetricsCollector>>,
}

impl SysmonService {
    pub fn new(collector: MetricsCollector) -> Self {
        Self {
            collector: Arc::new(RwLock::new(collector)),
        }
    }

    pub async fn start(&self, config: Arc<Config>) -> Result<ServerHandle> {
        let addr: SocketAddr = config.listen_addr.parse().context("Failed to parse listen address")?;
        info!("Starting gRPC sysmon service on {}", addr);

        // Use the existing collector Arc<RwLock<MetricsCollector>>
        let service = Arc::new(Self {
            collector: Arc::clone(&self.collector),
        });

        let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
        health_reporter.set_serving::<AgentServiceServer<Arc<SysmonService>>>().await;

        let reflection_service = ReflectionBuilder::configure()
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
            .build()?;

        let mut server_builder = Server::builder();
        if let Some(security) = &config.security {
            if security.tls_enabled {
                let cert = fs::read_to_string(security.cert_file.as_ref().unwrap())
                    .context("Failed to read certificate file")?;
                let key = fs::read_to_string(security.key_file.as_ref().unwrap())
                    .context("Failed to read key file")?;
                let identity = tonic::transport::Identity::from_pem(cert.as_bytes(), key.as_bytes());

                let ca_cert = fs::read_to_string(security.ca_file.as_ref().unwrap())
                    .context("Failed to read CA certificate file")?;
                let ca = tonic::transport::Certificate::from_pem(ca_cert.as_bytes());

                let tls_config = tonic::transport::ServerTlsConfig::new()
                    .identity(identity)
                    .client_ca_root(ca);
                server_builder = server_builder.tls_config(tls_config)?;
                info!("TLS configured with mTLS enabled");
            }
        }

        let server_handle = tokio::spawn(async move {
            server_builder
                .add_service(health_service)
                .add_service(AgentServiceServer::new(Arc::clone(&service)))
                .add_service(reflection_service)
                .serve(addr)
                .await
                .context("gRPC server error")?;
            Ok::<(), anyhow::Error>(())
        });

        Ok(ServerHandle { join_handle: server_handle })
    }
}

#[tonic::async_trait]
impl AgentService for SysmonService {
    async fn get_status(
        &self,
        request: Request<monitoring::StatusRequest>,
    ) -> Result<Response<monitoring::StatusResponse>, Status> {
        let req = request.into_inner();
        debug!("Received GetStatus: service_name={}, service_type={}, details={}",
               req.service_name, req.service_type, req.details);

        let start_time = std::time::Instant::now();
        let mut collector = self.collector.write().await;
        let metrics = collector.collect().await.map_err(|e| {
            Status::internal(format!("Failed to collect metrics: {}", e))
        })?;

        let message = serde_json::to_string(&metrics).map_err(|e| {
            Status::internal(format!("Failed to serialize metrics: {}", e))
        })?;

        let response_time = start_time.elapsed().as_nanos() as i64;
        Ok(Response::new(monitoring::StatusResponse {
            available: true,
            message,
            service_name: req.service_name,
            service_type: req.service_type,
            response_time,
        }))
    }
}

#[tonic::async_trait]
impl AgentService for Arc<SysmonService> {
    async fn get_status(
        &self,
        request: Request<monitoring::StatusRequest>,
    ) -> Result<Response<monitoring::StatusResponse>, Status> {
        (**self).get_status(request).await
    }
}

#[derive(Debug)]
pub struct ServerHandle {
    join_handle: JoinHandle<Result<()>>,
}

impl ServerHandle {
    pub async fn stop(self) -> Result<()> {
        self.join_handle.abort();
        match self.join_handle.await {
            Ok(result) => result,
            Err(e) if e.is_cancelled() => Ok(()),
            Err(e) => Err(anyhow::anyhow!("Server task failed: {}", e)),
        }
    }
}