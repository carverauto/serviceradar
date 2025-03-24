use anyhow::{Context, Result};
use log::{debug, error, info, warn};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use tokio::time::Duration;
use tonic::{Request, Response, Status};
use tonic::transport::Server;

use crate::config::{Config, TargetConfig};
use crate::poller::TargetPoller;
use crate::rperf::{RPerfResult, RPerfRunner};

// Include the generated proto code
pub mod rperf_service {
    tonic::include_proto!("rperf");
}

use rperf_service::{
    rperf_service_server::{RPerfService, RPerfServiceServer},
    StatusRequest, StatusResponse, TestRequest, TestResponse, TestSummary,
};

/// The main server struct for managing the gRPC service and pollers
#[derive(Debug)]
pub struct RPerfServer {
    config: Arc<Config>,
    target_pollers: Arc<Mutex<Vec<TargetPoller>>>,
}

impl RPerfServer {
    /// Create a new RPerfServer with the provided configuration
    pub fn new(config: Arc<Config>) -> Result<Self> {
        // Create pollers for each target
        let mut pollers = Vec::new();
        for target in &config.targets {
            let poller = TargetPoller::new(target.clone(), config.default_poll_interval);
            pollers.push(poller);
        }

        Ok(Self {
            config,
            target_pollers: Arc::new(Mutex::new(pollers)),
        })
    }

    /// Start the gRPC server and polling tasks
    pub async fn start(&self) -> Result<ServerHandle> {
        let addr: SocketAddr = self.config.listen_addr.parse()
            .context("Failed to parse listen address")?;

        info!("Starting rperf gRPC server on {}", addr);

        let pollers = self.target_pollers.clone();

        // Spawn a task to run all tests sequentially
        let poller_handle = tokio::spawn(async move {
            loop {
                let mut pollers = pollers.lock().await;
                for poller in pollers.iter_mut() {
                    info!("Running scheduled test for target: {}", poller.target_name());
                    match poller.run_single_test().await {
                        Ok(result) => {
                            if result.success {
                                info!("Test for target '{}' completed: {:.2} Mbps",
                                    poller.target_name(), result.summary.bits_per_second / 1_000_000.0);
                            } else {
                                warn!("Test for target '{}' failed: {}",
                                    poller.target_name(), result.error.as_deref().unwrap_or("Unknown error"));
                            }
                        },
                        Err(e) => error!("Error running test for target '{}': {}", poller.target_name(), e),
                    }

                    // Wait before the next test using the target's poll interval
                    let interval = poller.get_poll_interval();
                    tokio::time::sleep(interval).await;
                }

                // Small delay between full cycles
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        });

        // Create the gRPC service
        let service = RPerfServiceImpl {
            config: self.config.clone(),
            target_pollers: self.target_pollers.clone(),
        };

        // Start the gRPC server
        let server_handle = tokio::spawn(async move {
            Server::builder()
                .add_service(RPerfServiceServer::new(service))
                .serve(addr)
                .await
                .context("gRPC server error")?;
            Ok::<(), anyhow::Error>(())
        });

        Ok(ServerHandle {
            join_handle: server_handle,
            poller_handle,
            pollers: self.target_pollers.clone(),
        })
    }
}

// GRPC service implementation
struct RPerfServiceImpl {
    config: Arc<Config>,
    target_pollers: Arc<Mutex<Vec<TargetPoller>>>,
}

#[tonic::async_trait]
impl RPerfService for RPerfServiceImpl {
    async fn run_test(
        &self,
        request: Request<TestRequest>,
    ) -> std::result::Result<Response<TestResponse>, Status> {
        let req = request.into_inner();
        info!("Received test request for {}", req.target_address);

        // Create runner from request
        let runner = RPerfRunner::from_grpc_request(req);

        // Run the test
        match runner.run_test().await {
            Ok(result) => {
                let response = TestResponse {
                    success: result.success,
                    error: result.error.unwrap_or_default(),
                    results_json: result.results_json,
                    summary: Some(TestSummary {
                        duration: result.summary.duration,
                        bytes_sent: result.summary.bytes_sent,
                        bytes_received: result.summary.bytes_received,
                        bits_per_second: result.summary.bits_per_second,
                        packets_sent: result.summary.packets_sent,
                        packets_received: result.summary.packets_received,
                        packets_lost: result.summary.packets_lost,
                        loss_percent: result.summary.loss_percent,
                        jitter_ms: result.summary.jitter_ms,
                    }),
                };
                Ok(Response::new(response))
            },
            Err(e) => {
                error!("Error running test: {}", e);
                let response = TestResponse {
                    success: false,
                    error: format!("Internal server error: {}", e),
                    results_json: String::new(),
                    summary: None,
                };
                Ok(Response::new(response))
            }
        }
    }

    async fn get_status(
        &self,
        _request: Request<StatusRequest>,
    ) -> std::result::Result<Response<StatusResponse>, Status> {
        // Get status of all pollers
        let pollers = self.target_pollers.lock().await;
        let targets_count = pollers.len();

        let response = StatusResponse {
            available: true,
            version: env!("CARGO_PKG_VERSION").to_string(),
            message: format!("Service is running with {} configured targets", targets_count),
        };

        Ok(Response::new(response))
    }
}

/// Server handle for managing the running server
#[derive(Debug)]
pub struct ServerHandle {
    join_handle: JoinHandle<Result<()>>,
    poller_handle: JoinHandle<()>,
    pollers: Arc<Mutex<Vec<TargetPoller>>>,
}

impl ServerHandle {
    /// Stop the server and all pollers
    pub async fn stop(self) -> Result<()> {
        // Abort both tasks
        self.join_handle.abort();
        self.poller_handle.abort();

        // Stop all pollers
        for poller in self.pollers.lock().await.iter_mut() {
            if let Err(e) = poller.stop().await {
                error!("Error stopping poller for {}: {}", poller.target_name(), e);
            }
        }

        // Check server join handle results
        match self.join_handle.await {
            Ok(result) => result,
            Err(e) if e.is_cancelled() => Ok(()),
            Err(e) => Err(anyhow::anyhow!("Server task failed: {}", e)),
        }
    }
}