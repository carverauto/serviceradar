use anyhow::{Context, Result};
use log::{info, error, debug, warn};
use reqwest::Client;
use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::time::{interval, sleep};
use tonic::{
    transport::{Server, Channel, ServerTlsConfig, ClientTlsConfig, Identity, Certificate},
    Request, Response, Status,
};
use tonic_health::pb::HealthCheckRequest;
use tonic_health::pb::health_client::HealthClient;
use tonic_reflection::server::Builder as ReflectionBuilder;
use rand::Rng;
use futures::future;

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
    streams_setup: Arc<AtomicBool>,
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

        let processors: Vec<Box<dyn DataProcessor>> = vec![
            Box::new(SysmonProcessor {}),
            Box::new(RperfProcessor {}),
        ];

        let adapter = Self {
            processors: Arc::new(processors),
            client: Arc::new(Mutex::new(client)),
            proton_url: config.proton_url.clone(),
            poller_id: config.poller_id.clone(),
            forward_to_core: config.forward_to_core,
            core_client,
            streams_setup: Arc::new(AtomicBool::new(false)),
        };

        // Start background task to handle stream setup retries
        let adapter_clone = adapter.clone();
        tokio::spawn(async move {
            adapter_clone.run_stream_setup_retries(Duration::from_secs(300)).await;
        });

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

    /// Performs an exponential backoff retry for the given async operation.
    async fn exponential_backoff<F, Fut, T>(
        &self,
        operation: F,
        max_retries: usize,
        operation_name: &str,
    ) -> Result<T>
    where
        F: Fn() -> Fut,
        Fut: std::future::Future<Output = Result<T>>,
    {
        let mut attempts = 0;
        let base_delay = Duration::from_secs(1);
        let max_delay = Duration::from_secs(32);

        while attempts <= max_retries {
            match operation().await {
                Ok(result) => return Ok(result),
                Err(e) if attempts < max_retries => {
                    attempts += 1;
                    let delay = base_delay * 2u32.pow(attempts as u32);
                    let capped_delay = delay.min(max_delay);
                    let jitter = Duration::from_millis(rand::thread_rng().gen_range(0..100));
                    let total_delay = capped_delay + jitter;
                    error!(
                        "{} failed (attempt {}/{}): {}. Retrying after {:.2}s",
                        operation_name,
                        attempts,
                        max_retries,
                        e,
                        total_delay.as_secs_f32()
                    );
                    sleep(total_delay).await;
                }
                Err(e) => {
                    error!("{} failed after {} attempts: {}", operation_name, attempts + 1, e);
                    return Err(e);
                }
            }
        }
        Err(anyhow::anyhow!("Max retries reached for {}", operation_name))
    }

    /// Runs a background task to periodically retry stream setup every retry_interval.
    async fn run_stream_setup_retries(&self, retry_interval: Duration) {
        let mut interval = interval(retry_interval);

        loop {
            interval.tick().await;

            // Only try to set up streams if we need to
            if !self.streams_setup.load(Ordering::SeqCst) {
                // Check if Proton URL is empty or localhost
                if self.proton_url.is_empty() || self.proton_url.contains("localhost") {
                    // Log once at startup that we're skipping Proton setup
                    static LOGGED: AtomicBool = AtomicBool::new(false);
                    if !LOGGED.swap(true, Ordering::SeqCst) {
                        info!("Proton URL is empty or localhost, skipping stream setup");
                    }

                    // Wait for the next interval before checking again
                    continue;
                }

                info!("Attempting to set up Proton streams");
                match self.setup_all_streams().await {
                    Ok(_) => {
                        info!("Successfully set up all Proton streams");
                        self.streams_setup.store(true, Ordering::SeqCst);
                    }
                    Err(e) => {
                        error!("Failed to set up Proton streams: {}. Will retry in {:?}", e, retry_interval);
                    }
                }
            }
        }
    }



    pub async fn start_polling(&self, config: Arc<Config>) -> Result<()> {
        let mut interval_timer = interval(Duration::from_secs(config.poll_interval));
        let batch_size = get_batch_size(&config);
        let agent_concurrency = std::cmp::min(config.agents.len(), 5); // Limit number of concurrent agents

        info!(
        "Starting polling with batch size {} and agent concurrency {}",
        batch_size, agent_concurrency
    );

        loop {
            interval_timer.tick().await;

            // Process agents in chunks to limit overall concurrency
            for agent_chunk in config.agents.iter().collect::<Vec<_>>().chunks(agent_concurrency) {
                let mut agent_futures = Vec::with_capacity(agent_chunk.len());

                for (agent_name, agent_config) in agent_chunk {
                    #[allow(suspicious_double_ref_op)]
                    let agent_name = agent_name.clone(); // Clone String from &String
                    #[allow(suspicious_double_ref_op)]
                    let agent_config = agent_config.clone(); // Clone AgentConfig from &AgentConfig
                    let security = Some(config.security.clone());
                    let adapter = self.clone();

                    let agent_future = async move {
                        info!("Polling agent: {}", agent_name);
                        if let Err(e) = adapter
                            .poll_agent(agent_name, agent_config, &security, batch_size)
                            .await
                        {
                            error!("Failed to poll agent {}: {}", agent_name, e);
                        }
                    };

                    agent_futures.push(agent_future);
                }

                // Poll this batch of agents in parallel
                future::join_all(agent_futures).await;
            }
        }
    }

    async fn poll_agent(
        &self,
        agent_name: &str,
        agent_config: &AgentConfig,
        security: &Option<SecurityConfig>,
        batch_size: usize,
    ) -> Result<()> {
        self.exponential_backoff(
            || async {
                // Perform health check
                self.ensure_agent_health(&agent_config.address, security).await?;

                // Connect to agent
                let channel = Self::create_channel(&agent_config.address, security)
                    .await
                    .context(format!("Failed to connect to agent at {}", agent_config.address))?;
                let client = proto::agent_service_client::AgentServiceClient::new(channel);

                // Group checks into batches
                let checks = &agent_config.checks;
                let total_checks = checks.len();
                let mut all_services = Vec::with_capacity(total_checks);

                info!("Processing {} checks for agent {} in batches of {}",
                 total_checks, agent_name, batch_size);

                // Process checks in batches
                for chunk in checks.chunks(batch_size) {
                    let mut check_futures = Vec::with_capacity(chunk.len());

                    for check in chunk {
                        let check_clone = check.clone();
                        let mut client_clone = client.clone();

                        // Create a future for each check in this batch
                        let check_future = async move {
                            info!("Executing check: {} ({})", check_clone.service_name, check_clone.service_type);
                            let request = Request::new(proto::StatusRequest {
                                service_name: check_clone.service_name.clone(),
                                service_type: check_clone.service_type.clone(),
                                details: check_clone.details.clone().unwrap_or_default(),
                                port: check_clone.port.unwrap_or(0),
                            });

                            match client_clone.get_status(request).await {
                                Ok(response) => {
                                    let response = response.into_inner();
                                    Ok::<ServiceStatus, anyhow::Error>(ServiceStatus {
                                        service_name: response.service_name,
                                        available: response.available,
                                        message: response.message,
                                        service_type: response.service_type,
                                        response_time: response.response_time,
                                    })
                                }
                                Err(e) => {
                                    error!("Check failed for {}/{}: {}",
              check_clone.service_type, check_clone.service_name, e);
                                    Ok::<ServiceStatus, anyhow::Error>(ServiceStatus {
                                        service_name: check_clone.service_name.clone(),
                                        available: false,
                                        message: format!("Check failed: {}", e),
                                        service_type: check_clone.service_type.clone(),
                                        response_time: 0,
                                    })
                                }
                            }
                        };

                        check_futures.push(check_future);
                    }

                    // Execute this batch of checks in parallel
                    let batch_results: Vec<Result<_, _>> = futures::future::join_all(check_futures).await;

                    // Collect successful results from this batch
                    let batch_services: Vec<ServiceStatus> = batch_results
                        .into_iter()
                        .filter_map(Result::ok)
                        .collect();

                    // Extend our collection of all services
                    all_services.extend(batch_services);
                }

                // Process all collected services
                if !all_services.is_empty() {
                    info!("Completed {} of {} checks for agent {}",
                     all_services.len(), total_checks, agent_name);
                    self.process_services(agent_name, &all_services).await?;
                } else {
                    warn!("No successful checks completed for agent {}", agent_name);
                }

                Ok(())
            },
            4, // Max retries
            &format!("poll agent {}", agent_name),
        ).await
    }

    async fn forward_to_core(&self, _poller_id: &str, services: &[ServiceStatus]) -> Result<()> {
        if let Some(core_client) = &self.core_client {
            let mut client = core_client.lock().await;

            // Convert ServiceStatus objects to proto::ServiceStatus for gRPC
            let service_statuses: Vec<proto::ServiceStatus> = services.iter()
                .map(|s| proto::ServiceStatus {
                    service_name: s.service_name.clone(),
                    available: s.available,
                    message: s.message.clone(),
                    service_type: s.service_type.clone(),
                    response_time: s.response_time,
                })
                .collect();

            let forwarded_req = proto::PollerStatusRequest {
                poller_id: self.poller_id.clone(), // Use adapter's poller_id
                services: service_statuses,
                timestamp: chrono::Utc::now().timestamp(),
            };

            match client.report_status(Request::new(forwarded_req)).await {
                Ok(_) => info!(
                "Successfully forwarded status to core for poller_id={}",
                self.poller_id
            ),
                Err(e) => error!("Failed to forward status to core: {}", e),
            }
        }

        Ok(())
    }

    async fn ensure_agent_health(
        &self,
        agent_addr: &str,
        security: &Option<SecurityConfig>,
    ) -> Result<()> {
        let addr = format!("http://{}", agent_addr);
        self.exponential_backoff(
            || async {
                info!("Checking health of agent at {}", addr);
                let channel = Self::create_channel(&addr, security)
                    .await
                    .context(format!("Failed to connect to agent at {}", agent_addr))?;
                let mut health_client = HealthClient::new(channel);
                let response = health_client
                    .check(HealthCheckRequest {
                        // service: "monitoring.AgentService".to_string(),
                        service: "".to_string(),
                    })
                    .await?;
                if response.get_ref().status != 1 {
                    return Err(anyhow::anyhow!("Agent {} is unhealthy", agent_addr));
                }
                Ok(())
            },
            4, // Max retries
            &format!("health check for agent {}", agent_addr),
        ).await
    }

    async fn setup_all_streams(&self) -> Result<()> {
        let client = self.client.lock().await;
        for processor in self.processors.iter() {
            info!("Setting up streams for processor: {}", processor.name());
            self.exponential_backoff(
                || async {
                    processor.setup_streams(&client, &self.proton_url).await
                },
                4, // Max retries
                &format!("setup streams for processor {}", processor.name()),
            )
                .await
                .map_err(|e| {
                    error!("Failed to set up streams for processor {}: {}", processor.name(), e);
                    e
                })?;
        }
        Ok(())
    }

    async fn process_services(&self, poller_id: &str, services: &[ServiceStatus]) -> Result<()> {
        // Check if Proton streams are setup before attempting to process data with Proton
        if !self.streams_setup.load(Ordering::SeqCst) {
            debug!("Skipping Proton processing for {}: Proton streams not set up", poller_id);

            // Still forward to core if configured, even if Proton isn't available
            if self.forward_to_core && self.core_client.is_some() {
                self.forward_to_core(poller_id, services).await?;
            }

            return Ok(());
        }

        // Original Proton processing logic
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

        // Always forward to core if configured, even after Proton processing
        if self.forward_to_core && self.core_client.is_some() {
            self.forward_to_core(poller_id, services).await?;
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

        // Convert proto::ServiceStatus to our internal ServiceStatus type
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

        // Process services (will handle Proton and forwarding)
        if let Err(e) = self.process_services(&poller_id, &services).await {
            error!("Error processing services for poller {}: {}", poller_id, e);
        }

        // Always return success to prevent unnecessary retries
        Ok(Response::new(proto::PollerStatusResponse { received: true }))
    }
}

fn get_batch_size(config: &Config) -> usize {
    config.batch_size.unwrap_or(20) // Default to 20 concurrent checks per agent
}