use anyhow::{Context, Result};
use log::{info, error};
use reqwest::Client;
use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::interval;
use tonic::{
    transport::{Server, Channel, ServerTlsConfig, ClientTlsConfig, Identity, Certificate},
    Request, Response, Status,
};
use tonic_health::pb::HealthCheckRequest;
use tonic_health::pb::health_client::HealthClient;
use tonic_reflection::server::Builder as ReflectionBuilder;

use crate::processors::{sysmon::SysmonProcessor, rperf::RperfProcessor};
use crate::models::types::ServiceStatus;
use crate::processor::DataProcessor;
use crate::{Config, AgentConfig, SecurityConfig};

// Import proto definitions
pub mod proto {
    tonic::include_proto!("monitoring");
}

const FILE_DESCRIPTOR_SET_MONITORING: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/monitoring_descriptor.bin"));

#[derive(Clone)]
pub struct ProtonAdapter {
    processors: Arc<Vec<Box<dyn DataProcessor>>>,
    client: Arc<Mutex<Client>>,
    proton_url: String,
    poller_id: String,
    forward_to_core: bool,
    core_client: Option<Arc<Mutex<proto::poller_service_client::PollerServiceClient<Channel>>>>,
}

impl ProtonAdapter {
    pub async fn new(config: &Config) -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .context("Failed to create HTTP client")?;

        let core_client = if config.forward_to_core && config.core_address.is_some() {
            let addr = config.core_address.as_ref().unwrap();
            info!("Connecting to core service at {}", addr);
            let channel = Self::create_channel(addr, &Some(config.security.clone())).await
                .context(format!("Failed to connect to core service at {}", addr))?;
            let client = proto::poller_service_client::PollerServiceClient::new(channel);
            Some(Arc::new(Mutex::new(client)))
        } else {
            None
        };

        let mut processors: Vec<Box<dyn DataProcessor>> = Vec::new();
        processors.push(Box::new(SysmonProcessor {}));
        processors.push(Box::new(RperfProcessor {}));

        let adapter = Self {
            processors: Arc::new(processors),
            client: Arc::new(Mutex::new(client)),
            proton_url: config.proton_url.clone(),
            poller_id: config.poller_id.clone(),
            forward_to_core: config.forward_to_core,
            core_client,
        };

        adapter.setup_all_streams().await?;
        Ok(adapter)
    }

    async fn create_channel(addr: &str, security: &Option<SecurityConfig>) -> Result<Channel> {
        let addr = if !addr.starts_with("http://") && !addr.starts_with("https://") {
            format!("https://{}", addr) // Use https for mTLS
        } else {
            addr.to_string()
        };
        let mut endpoint = Channel::from_shared(addr)?;
        if let Some(security) = security {
            if security.tls.enabled {
                let cert_dir = &security.cert_dir;
                let cert_path = Path::new(cert_dir).join(&security.tls.cert_file);
                let key_path = Path::new(cert_dir).join(&security.tls.key_file);
                let ca_path = Path::new(cert_dir).join(&security.tls.ca_file);
                let client_ca_path = Path::new(cert_dir).join(&security.tls.client_ca_file);

                let ca_cert = fs::read_to_string(&ca_path)
                    .context(format!("Failed to read CA certificate file: {:?}", ca_path))?;
                let ca = Certificate::from_pem(ca_cert);
                let cert = fs::read_to_string(&cert_path)
                    .context(format!("Failed to read certificate file: {:?}", cert_path))?;
                let key = fs::read_to_string(&key_path)
                    .context(format!("Failed to read key file: {:?}", key_path))?;
                let identity = Identity::from_pem(cert.as_bytes(), key.as_bytes());

                let mut tls_config = ClientTlsConfig::new()
                    .ca_certificate(ca)
                    .identity(identity)
                    .domain_name(&security.server_name);

                if security.mode == "mtls" {
                    let client_ca_cert = fs::read_to_string(&client_ca_path)
                        .context(format!(
                            "Failed to read client CA certificate file: {:?}",
                            client_ca_path
                        ))?;
                    let client_ca = Certificate::from_pem(client_ca_cert);
                    tls_config = tls_config.ca_certificate(client_ca);
                }

                endpoint = endpoint
                    .tls_config(tls_config)
                    .context("Failed to configure TLS")?;
            }
        }
        endpoint.connect().await.context("Failed to connect")
    }

    pub async fn start_polling(&self, config: Arc<Config>) -> Result<()> {
        let mut interval_timer = interval(Duration::from_secs(config.poll_interval));
        loop {
            interval_timer.tick().await;
            for (agent_name, agent_config) in &config.agents {
                info!("Polling agent: {}", agent_name);
                if let Err(e) = self
                    .poll_agent(agent_name, agent_config, &Some(config.security.clone()))
                    .await
                {
                    error!("Failed to poll agent {}: {}", agent_name, e);
                }
            }
        }
    }

    async fn poll_agent(
        &self,
        agent_name: &str,
        agent_config: &AgentConfig,
        security: &Option<SecurityConfig>,
    ) -> Result<()> {
        for attempt in 1..=3 {
            match self.ensure_agent_health(&agent_config.address, security).await {
                Ok(_) => break,
                Err(e) if attempt < 3 => {
                    error!("Health check failed for agent {} (attempt {}): {}", agent_name, attempt, e);
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
                Err(e) => return Err(e),
            }
        }

        let channel = Self::create_channel(&agent_config.address, security)
            .await
            .context(format!("Failed to connect to agent at {}", agent_config.address))?;
        let mut client = proto::agent_service_client::AgentServiceClient::new(channel);

        let mut services = Vec::new();
        for check in &agent_config.checks {
            info!("Executing check: {} ({})", check.service_name, check.service_type);
            let request = Request::new(proto::StatusRequest {
                service_name: check.service_name.clone(),
                service_type: check.service_type.clone(),
                details: check.details.clone().unwrap_or_default(),
                port: check.port.unwrap_or(0),
            });

            match client.get_status(request).await {
                Ok(response) => {
                    let response = response.into_inner();
                    services.push(ServiceStatus {
                        service_name: response.service_name,
                        available: response.available,
                        message: response.message,
                        service_type: response.service_type,
                        response_time: response.response_time,
                    });
                }
                Err(e) => {
                    error!("Check failed for {}/{}: {}", check.service_type, check.service_name, e);
                    services.push(ServiceStatus {
                        service_name: check.service_name.clone(),
                        available: false,
                        message: format!("Check failed: {}", e),
                        service_type: check.service_type.clone(),
                        response_time: 0,
                    });
                }
            }
        }

        let poller_id = agent_name.to_string();
        self.process_services(&poller_id, &services).await?;
        Ok(())
    }

    async fn ensure_agent_health(
        &self,
        agent_addr: &str,
        security: &Option<SecurityConfig>,
    ) -> Result<()> {
        let addr = format!("http://{}", agent_addr);
        info!("Checking health of agent at {}", addr);
        let channel = Self::create_channel(&addr, security)
            .await
            .context(format!("Failed to connect to agent at {}", agent_addr))?;
        let mut health_client = HealthClient::new(channel);
        let response = health_client
            .check(HealthCheckRequest {
                service: "monitoring.AgentService".to_string(),
            })
            .await?;
        if response.get_ref().status != 1 {
            // Compare with 1 (ServingStatus::Serving)
            return Err(anyhow::anyhow!("Agent {} is unhealthy", agent_addr));
        }
        Ok(())
    }

    async fn setup_all_streams(&self) -> Result<()> {
        let client = self.client.lock().await;
        for processor in self.processors.iter() {
            info!("Setting up streams for processor: {}", processor.name());
            if let Err(e) = processor.setup_streams(&client, &self.proton_url).await {
                error!("Failed to set up streams for processor {}: {}", processor.name(), e);
            }
        }
        Ok(())
    }

    async fn process_services(&self, poller_id: &str, services: &[ServiceStatus]) -> Result<()> {
        let client = self.client.lock().await;
        for service in services {
            for processor in self.processors.iter() {
                if processor.handles_service(&service.service_type, &service.service_name) {
                    info!(
                        "Processing service {} with processor {}",
                        service.service_name,
                        processor.name()
                    );
                    if let Err(e) = processor
                        .process_service(poller_id, service, &client, &self.proton_url)
                        .await
                    {
                        error!(
                            "Error processing service {} with processor {}: {}",
                            service.service_name,
                            processor.name(),
                            e
                        );
                    }
                }
            }
        }
        Ok(())
    }

    pub async fn serve(&self, addr: String, security: Option<SecurityConfig>) -> Result<()> {
        let addr = addr.parse().context("Failed to parse address")?;
        info!("Starting gRPC server on {}", addr);

        let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
        health_reporter
            .set_serving::<proto::poller_service_server::PollerServiceServer<ProtonAdapter>>()
            .await;

        let reflection_service = ReflectionBuilder::configure()
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
            .build()?;

        let mut server_builder = Server::builder();
        if let Some(security) = security {
            if security.tls.enabled {
                info!("Configuring TLS for gRPC server");
                let cert_dir = &security.cert_dir;
                let cert_path = Path::new(cert_dir).join(&security.tls.cert_file);
                let key_path = Path::new(cert_dir).join(&security.tls.key_file);
                let ca_path = Path::new(cert_dir).join(&security.tls.ca_file);

                let cert = fs::read_to_string(&cert_path)
                    .context(format!("Failed to read certificate file: {:?}", cert_path))?;
                let key = fs::read_to_string(&key_path)
                    .context(format!("Failed to read key file: {:?}", key_path))?;
                let identity = Identity::from_pem(cert.as_bytes(), key.as_bytes());
                let ca_cert = fs::read_to_string(&ca_path)
                    .context(format!("Failed to read CA certificate file: {:?}", ca_path))?;
                let ca = Certificate::from_pem(ca_cert.as_bytes());
                let tls_config = ServerTlsConfig::new()
                    .identity(identity)
                    .client_ca_root(ca);
                server_builder = server_builder
                    .tls_config(tls_config)
                    .context("Failed to configure TLS")?;
            }
        }

        server_builder
            .add_service(health_service)
            .add_service(proto::poller_service_server::PollerServiceServer::new(self.clone()))
            .add_service(reflection_service)
            .serve(addr)
            .await
            .context("gRPC server failed")?;

        Ok(())
    }
}

#[tonic::async_trait]
impl proto::poller_service_server::PollerService for ProtonAdapter {
    async fn report_status(
        &self,
        request: Request<proto::PollerStatusRequest>,
    ) -> Result<Response<proto::PollerStatusResponse>, Status> {
        let req = request.into_inner();
        let poller_id = req.poller_id.clone();
        info!(
            "Received status report from poller_id={} with {} services",
            poller_id,
            req.services.len()
        );

        let services: Vec<ServiceStatus> = req
            .services
            .iter()
            .map(|s| ServiceStatus {
                service_name: s.service_name.clone(),
                available: s.available,
                message: s.message.clone(),
                service_type: s.service_type.clone(),
                response_time: s.response_time,
            })
            .collect();

        if let Err(e) = self.process_services(&poller_id, &services).await {
            error!("Error processing services for poller {}: {}", poller_id, e);
        }

        if self.forward_to_core && self.core_client.is_some() {
            let mut core_client = self.core_client.as_ref().unwrap().lock().await;
            let forwarded_req = proto::PollerStatusRequest {
                poller_id: self.poller_id.clone(), // Use adapter's poller_id
                services: req.services.clone(),
                timestamp: chrono::Utc::now().timestamp(),
            };
            match core_client.report_status(Request::new(forwarded_req)).await {
                Ok(_) => info!(
                    "Successfully forwarded status to core for poller_id={}",
                    self.poller_id
                ),
                Err(e) => error!("Failed to forward status to core: {}", e),
            }
        }

        Ok(Response::new(proto::PollerStatusResponse { received: true }))
    }
}