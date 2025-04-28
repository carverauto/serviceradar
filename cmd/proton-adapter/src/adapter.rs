use anyhow::{Context, Result};
use log::{info, error};
use reqwest::Client;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tonic::{transport::Server, Request, Response, Status};

use crate::processor::DataProcessor;
use crate::processors::{sysmon::SysmonProcessor, rperf::RperfProcessor};
use crate::models::types::ServiceStatus;

// Import the proto definitions
pub mod monitoring {
    tonic::include_proto!("monitoring");
}

use monitoring::poller_service_server::{PollerService, PollerServiceServer};
use monitoring::{PollerStatusRequest, PollerStatusResponse};

pub struct ProtonAdapter {
    processors: Vec<Box<dyn DataProcessor>>,
    client: Arc<Mutex<Client>>,
    proton_url: String,
    forward_to_core: bool,
    core_client: Option<Arc<Mutex<monitoring::poller_service_client::PollerServiceClient<tonic::transport::Channel>>>>,
}

impl ProtonAdapter {
    pub async fn new(proton_url: String, forward_to_core: bool, core_address: Option<String>) -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .context("Failed to create HTTP client")?;

        let core_client = if forward_to_core && core_address.is_some() {
            let addr = core_address.unwrap();
            let client = monitoring::poller_service_client::PollerServiceClient::connect(addr)
                .await
                .context("Failed to connect to core service")?;
            Some(Arc::new(Mutex::new(client)))
        } else {
            None
        };

        // Create the adapter with all processors
        let mut adapter = Self {
            processors: Vec::new(),
            client: Arc::new(Mutex::new(client)),
            proton_url,
            forward_to_core,
            core_client,
        };

        // Register processors
        adapter.register_processor(Box::new(SysmonProcessor {}));
        adapter.register_processor(Box::new(RperfProcessor {}));
        // Register more processors here as needed

        // Setup streams for all processors
        adapter.setup_all_streams().await?;

        Ok(adapter)
    }

    fn register_processor(&mut self, processor: Box<dyn DataProcessor>) {
        info!("Registering processor: {}", processor.name());
        self.processors.push(processor);
    }

    async fn setup_all_streams(&self) -> Result<()> {
        let client = self.client.lock().await;

        for processor in &self.processors {
            info!("Setting up streams for processor: {}", processor.name());
            if let Err(e) = processor.setup_streams(&client, &self.proton_url).await {
                error!("Failed to set up streams for processor {}: {}", processor.name(), e);
                // Continue with other processors
            }
        }

        Ok(())
    }

    async fn process_services(&self, poller_id: &str, services: &[ServiceStatus]) -> Result<()> {
        let client = self.client.lock().await;

        for service in services {
            for processor in &self.processors {
                if processor.handles_service(&service.service_type, &service.service_name) {
                    info!("Processing service {} with processor {}",
                         service.service_name, processor.name());

                    if let Err(e) = processor.process_service(
                        poller_id, service, &client, &self.proton_url).await {
                        error!("Error processing service {} with processor {}: {}",
                             service.service_name, processor.name(), e);
                    }
                }
            }
        }

        Ok(())
    }

    pub async fn serve(&self, addr: String) -> Result<()> {
        let addr = addr.parse().context("Failed to parse address")?;

        info!("Starting gRPC server on {}", addr);

        Server::builder()
            .add_service(PollerServiceServer::new(self.clone()))
            .serve(addr)
            .await
            .context("gRPC server failed")?;

        Ok(())
    }
}

impl Clone for ProtonAdapter {
    fn clone(&self) -> Self {
        // This is a shallow clone that shares the Arc references
        Self {
            processors: self.processors.clone(),
            client: Arc::clone(&self.client),
            proton_url: self.proton_url.clone(),
            forward_to_core: self.forward_to_core,
            core_client: self.core_client.clone(),
        }
    }
}

#[tonic::async_trait]
impl PollerService for ProtonAdapter {
    async fn report_status(
        &self,
        request: Request<PollerStatusRequest>,
    ) -> Result<Response<PollerStatusResponse>, Status> {
        let req = request.into_inner();
        let poller_id = req.poller_id.clone();

        info!("Received status report from poller_id={} with {} services",
                  poller_id, req.services.len());

        // Convert proto services to our ServiceStatus struct
        let services: Vec<ServiceStatus> = req.services.iter()
            .map(|s| ServiceStatus {
                service_name: s.service_name.clone(),
                available: s.available,
                message: s.message.clone(),
                service_type: s.service_type.clone(),
                response_time: s.response_time,
            })
            .collect();

        // Process all services
        if let Err(e) = self.process_services(&poller_id, &services).await {
            error!("Error processing services for poller {}: {}", poller_id, e);
        }

        // Forward to core if needed
        if self.forward_to_core && self.core_client.is_some() {
            let mut core_client = self.core_client.as_ref().unwrap().lock().await;
            match core_client.report_status(Request::new(req.clone())).await {
                Ok(_) => info!("Successfully forwarded status to core for poller_id={}", poller_id),
                Err(e) => error!("Failed to forward status to core: {}", e),
            }
        }

        // Return success response
        Ok(Response::new(PollerStatusResponse {
            received: true,
        }))
    }
}