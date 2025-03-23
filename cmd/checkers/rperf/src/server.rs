use anyhow::{Context, Result};
use log::{error, info};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use tonic::{transport::Server, Request, Response, Status};

use crate::config::Config;
use crate::poller::TargetPoller;
use crate::rperf::RPerfRunner;

pub mod rperf_service {
    tonic::include_proto!("rperf");
}

use rperf_service::{
    r_perf_service_server::{RPerfService, RPerfServiceServer},
    StatusRequest, StatusResponse, TestRequest, TestResponse, TestSummary,
};

pub struct ServerHandle {
    join_handle: JoinHandle<Result<()>>,
    pollers: Arc<Mutex<Vec<TargetPoller>>>,
}

impl ServerHandle {
    pub async fn stop(self) -> Result<()> {
        self.join_handle.abort();
        for poller in self.pollers.lock().await.iter_mut() {
            poller.stop().await?;
        }
        match self.join_handle.await {
            Ok(result) => result,
            Err(e) if e.is_cancelled() => Ok(()),
            Err(e) => Err(anyhow::anyhow!("Server task failed: {}", e)),
        }
    }
}

pub struct RPerfServer {
    config: Arc<Config>,
    target_pollers: Arc<Mutex<Vec<TargetPoller>>>,
}

#[derive(Debug)]
pub struct RPerfServiceImpl {
    config: Arc<Config>,
    target_pollers: Arc<Mutex<Vec<TargetPoller>>>,
}

impl RPerfServer {
    pub fn new(config: Arc<Config>) -> Result<Self> {
        let target_pollers = Arc::new(Mutex::new(Vec::new()));
        Ok(RPerfServer {
            config,
            target_pollers,
        })
    }

    pub async fn start(&self) -> Result<ServerHandle> {
        let addr: SocketAddr = self.config.listen_addr.parse()
            .context("Failed to parse listen address")?;
            
        info!("Starting rperf gRPC server on {}", addr);
        
        let mut poller_handles = Vec::new();
        {
            let mut pollers = self.target_pollers.lock().await;
            for target_config in &self.config.targets {
                let mut poller = TargetPoller::new(
                    target_config.clone(),
                    self.config.default_poll_interval,
                );
                poller.start().await?;
                if let Some(handle) = poller.task_handle.lock().await.take() {
                    poller_handles.push(handle);
                }
                pollers.push(poller);
            }
        }

        let service = RPerfServiceImpl {
            config: self.config.clone(),
            target_pollers: self.target_pollers.clone(),
        };

        let join_handle = tokio::spawn(async move {
            Server::builder()
                .add_service(RPerfServiceServer::new(service))
                .serve(addr)
                .await
                .context("gRPC server error")?;

            // Wait for all poller tasks to complete
            for handle in poller_handles {
                if let Err(e) = handle.await {
                    error!("Poller task failed: {}", e);
                }
            }
            info!("All poller tasks completed, shutting down server");
            Ok(())
        });

        Ok(ServerHandle {
            join_handle,
            pollers: self.target_pollers.clone(),
        })
    }
}

#[tonic::async_trait]
impl RPerfService for RPerfServiceImpl {
    async fn run_test(
        &self,
        request: Request<TestRequest>,
    ) -> Result<Response<TestResponse>, Status> {
        let req = request.into_inner();
        info!("Received test request for target: {}", req.target_address);
        
        let rperf_req = RPerfRunner::from_grpc_request(req);
        
        match rperf_req.run_test().await {
            Ok(result) => {
                info!("Test completed successfully");
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
                error!("Test execution failed: {}", e);
                Err(Status::internal(format!("Test execution failed: {}", e)))
            }
        }
    }
    
    async fn get_status(
        &self,
        _request: Request<StatusRequest>,
    ) -> Result<Response<StatusResponse>, Status> {
        info!("Received status request");
        
        let pollers = self.target_pollers.lock().await;
        let mut message = String::new();
        
        if pollers.is_empty() {
            message = "No targets configured".to_string();
        } else {
            for (i, poller) in pollers.iter().enumerate() {
                let status = poller.get_last_result().await;
                message.push_str(&format!(
                    "Target {}: {} - {}\n",
                    i + 1,
                    poller.target_name(),
                    status.map_or("No data yet".to_string(), |s| {
                        if s.success {
                            format!("OK ({:.2} Mbps)", s.summary.bits_per_second / 1_000_000.0)
                        } else {
                            format!("Failed: {}", s.error.unwrap_or_default())
                        }
                    })
                ));
            }
        }
        
        let response = StatusResponse {
            available: true,
            version: env!("CARGO_PKG_VERSION").to_string(),
            message,
        };
        
        Ok(Response::new(response))
    }
}