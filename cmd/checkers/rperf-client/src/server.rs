/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use anyhow::{Context, Result};
use chrono;
use log::{debug, error, info, warn};
use std::fs;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::task::JoinHandle;
use tokio::time::{timeout, Duration};
use tonic::transport::Server;
use tonic::{Request, Response, Status};
use tonic_reflection::server::Builder as ReflectionBuilder;

use crate::config::Config;
use crate::poller::TargetPoller;
use crate::rperf::RPerfRunner;
use crate::server::monitoring::agent_service_server::{AgentService, AgentServiceServer};

const FILE_DESCRIPTOR_SET_RPERF: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/rperf_descriptor.bin"));
const FILE_DESCRIPTOR_SET_MONITORING: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/monitoring_descriptor.bin"));

pub mod rperf_service {
    tonic::include_proto!("rperf");
}

pub mod monitoring {
    tonic::include_proto!("monitoring");
}

use rperf_service::{
    r_perf_service_server::{RPerfService, RPerfServiceServer},
    StatusRequest, StatusResponse, TestRequest, TestResponse, TestSummary,
};

#[derive(Debug)]
pub struct RPerfTestOrchestrator {
    config: Arc<Config>,
    target_pollers: Arc<RwLock<Vec<TargetPoller>>>,
}

impl RPerfTestOrchestrator {
    pub fn new(config: Arc<Config>) -> Result<Self> {
        let mut pollers = Vec::new();
        for target in &config.targets {
            let poller = TargetPoller::new(target.clone(), config.default_poll_interval);
            pollers.push(poller);
        }
        Ok(Self {
            config,
            target_pollers: Arc::new(RwLock::new(pollers)),
        })
    }

    pub async fn start(&self) -> Result<ServerHandle> {
        let addr: SocketAddr = self
            .config
            .listen_addr
            .parse()
            .context("Failed to parse listen address")?;

        info!("Starting gRPC test orchestrator on {addr}");

        let pollers = self.target_pollers.clone();
        let poller_handle = tokio::spawn(async move {
            loop {
                {
                    let mut pollers = pollers.write().await;
                    for poller in pollers.iter_mut() {
                        info!(
                            "Running scheduled test for target: {}",
                            poller.target_name()
                        );
                        match poller.run_single_test().await {
                            Ok(result) => {
                                if result.success {
                                    info!(
                                        "Test for target '{}' completed: {:.2} Mbps",
                                        poller.target_name(),
                                        result.summary.bits_per_second / 1_000_000.0
                                    );
                                } else {
                                    warn!(
                                        "Test for target '{}' failed: {}",
                                        poller.target_name(),
                                        result.error.as_deref().unwrap_or("Unknown error")
                                    );
                                }
                            }
                            Err(e) => error!(
                                "Error running test for target '{}': {}",
                                poller.target_name(),
                                e
                            ),
                        }
                    }
                }
                let poll_interval = {
                    let pollers = pollers.read().await;
                    pollers
                        .iter()
                        .map(|p| p.get_poll_interval())
                        .min()
                        .unwrap_or(Duration::from_secs(300))
                };
                tokio::time::sleep(poll_interval).await;
            }
        });

        let service = Arc::new(RPerfServiceImpl {
            target_pollers: self.target_pollers.clone(),
        });

        let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
        health_reporter
            .set_serving::<RPerfServiceServer<RPerfServiceImpl>>()
            .await;
        health_reporter
            .set_serving::<AgentServiceServer<Arc<RPerfServiceImpl>>>()
            .await;

        let reflection_service = ReflectionBuilder::configure()
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_RPERF)
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
            .build()?;

        let mut server_builder = Server::builder();

        if let Some(security) = &self.config.security {
            if security.tls_enabled {
                let cert = fs::read_to_string(security.cert_file.as_ref().unwrap())
                    .context("Failed to read certificate file")?;
                let key = fs::read_to_string(security.key_file.as_ref().unwrap())
                    .context("Failed to read key file")?;
                let identity =
                    tonic::transport::Identity::from_pem(cert.as_bytes(), key.as_bytes());

                let ca_cert = fs::read_to_string(security.ca_file.as_ref().unwrap())
                    .context("Failed to read CA certificate file")?;
                let ca = tonic::transport::Certificate::from_pem(ca_cert.as_bytes());

                let tls_config = tonic::transport::ServerTlsConfig::new()
                    .identity(identity)
                    .client_ca_root(ca);
                debug!("TLS config created: {tls_config:?}");
                server_builder = server_builder.tls_config(tls_config)?;
                info!("TLS configured with mTLS enabled");
            }
        }

        let server_handle = tokio::spawn(async move {
            debug!("Registering services: health, RPerfService, AgentService, reflection");
            let result = server_builder
                .add_service(health_service)
                .add_service(RPerfServiceServer::new(Arc::clone(&service)))
                .add_service(AgentServiceServer::new(Arc::clone(&service)))
                .add_service(reflection_service)
                .serve(addr)
                .await
                .context("gRPC server error");
            debug!("Service registration completed: {result:?}");
            result?;
            info!("gRPC server started successfully on {addr}");
            Ok::<(), anyhow::Error>(())
        });

        Ok(ServerHandle {
            join_handle: server_handle,
            poller_handle,
            pollers: self.target_pollers.clone(),
        })
    }
}

struct RPerfServiceImpl {
    target_pollers: Arc<RwLock<Vec<TargetPoller>>>,
}

#[tonic::async_trait]
impl RPerfService for RPerfServiceImpl {
    async fn run_test(
        &self,
        request: Request<TestRequest>,
    ) -> Result<Response<TestResponse>, Status> {
        let req = request.into_inner();
        info!("Received test request for {}", req.target_address);
        let runner = RPerfRunner::from_grpc_request(req);
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
            }
            Err(e) => {
                error!("Error running test: {e}");
                Ok(Response::new(TestResponse {
                    success: false,
                    error: format!("Internal server error: {e}"),
                    results_json: String::new(),
                    summary: None,
                }))
            }
        }
    }

    async fn get_status(
        &self,
        _request: Request<StatusRequest>,
    ) -> Result<Response<StatusResponse>, Status> {
        let start_time = std::time::Instant::now();

        let pollers = match timeout(Duration::from_secs(1), self.target_pollers.read()).await {
            Ok(guard) => guard,
            Err(_) => {
                debug!("Timeout acquiring read lock on target_pollers, returning default response");
                let outer_data = serde_json::json!({
                    "error": "Service is running (status unavailable due to lock timeout)",
                    "response_time": 0,
                    "available": true
                });
                let message_bytes = serde_json::to_vec(&outer_data).unwrap_or_default();
                return Ok(Response::new(StatusResponse {
                    available: true,
                    message: message_bytes,
                    service_name: "rperf".to_string(),
                    service_type: "network_performance".to_string(),
                    response_time: 0,
                    agent_id: "".to_string(),
                    version: env!("CARGO_PKG_VERSION").to_string(),
                }));
            }
        };

        let mut results = Vec::new();
        for poller in pollers.iter() {
            if let Some(last_result) = &poller.last_result {
                let result_json = serde_json::json!({
                    "target": poller.target_name(),
                    "success": last_result.success,
                    "error": last_result.error,
                    "status": {
                        "duration": last_result.summary.duration,
                        "bytes_sent": last_result.summary.bytes_sent,
                        "bytes_received": last_result.summary.bytes_received,
                        "bits_per_second": last_result.summary.bits_per_second,
                        "packets_sent": last_result.summary.packets_sent,
                        "packets_received": last_result.summary.packets_received,
                        "packets_lost": last_result.summary.packets_lost,
                        "loss_percent": last_result.summary.loss_percent,
                        "jitter_ms": last_result.summary.jitter_ms,
                    }
                });
                results.push(result_json);
            } else {
                results.push(serde_json::json!({
                    "target": poller.target_name(),
                    "success": false,
                    "error": "No test results available yet",
                    "status": {}
                }));
            }
        }

        let outer_data = serde_json::json!({
            "status": {
                "results": results,
                "timestamp": chrono::Utc::now().to_rfc3339()
            },
            "response_time": start_time.elapsed().as_nanos() as i64,
            "available": !results.is_empty()
        });

        let message_bytes = serde_json::to_vec(&outer_data).unwrap_or_else(|e| {
            error!("Failed to serialize test results: {e}");
            serde_json::to_vec(&serde_json::json!({
                "error": "Failed to serialize test results",
                "response_time": start_time.elapsed().as_nanos() as i64,
                "available": false
            }))
            .unwrap_or_default()
        });

        let response_time = start_time.elapsed().as_nanos() as i64;

        Ok(Response::new(StatusResponse {
            available: !results.is_empty(),
            message: message_bytes,
            service_name: "rperf".to_string(),
            service_type: "network_performance".to_string(),
            response_time,
            agent_id: "".to_string(),
            version: env!("CARGO_PKG_VERSION").to_string(),
        }))
    }
}

#[tonic::async_trait]
impl AgentService for RPerfServiceImpl {
    async fn get_status(
        &self,
        request: Request<monitoring::StatusRequest>,
    ) -> Result<Response<monitoring::StatusResponse>, Status> {
        let req = request.into_inner();
        debug!(
            "Received GetStatus request: service_name={}, service_type={}, details={}",
            req.service_name, req.service_type, req.details
        );

        let start_time = std::time::Instant::now();

        let pollers = match timeout(Duration::from_secs(1), self.target_pollers.read()).await {
            Ok(guard) => guard,
            Err(_) => {
                let outer_data = serde_json::json!({
                    "error": "Service is running (status unavailable due to lock timeout)",
                    "response_time": 0,
                    "available": true
                });
                let message_bytes = serde_json::to_vec(&outer_data).unwrap_or_default();
                return Ok(Response::new(monitoring::StatusResponse {
                    available: true,
                    message: message_bytes,
                    service_name: req.service_name,
                    service_type: req.service_type,
                    response_time: 0,
                    agent_id: req.agent_id,
                }));
            }
        };

        let mut results = Vec::new();
        for poller in pollers.iter() {
            if (!req.details.is_empty() && poller.target_name() == req.details)
                || (!req.service_name.is_empty() && poller.target_name() == req.service_name)
                || (req.details.is_empty() && req.service_name.is_empty())
            {
                if let Some(last_result) = &poller.last_result {
                    let result_json = serde_json::json!({
                        "target": poller.target_name(),
                        "success": last_result.success,
                        "error": last_result.error,
                        "status": {
                            "bits_per_second": last_result.summary.bits_per_second,
                            "bytes_received": last_result.summary.bytes_received,
                            "bytes_sent": last_result.summary.bytes_sent,
                            "duration": last_result.summary.duration,
                            "jitter_ms": last_result.summary.jitter_ms,
                            "loss_percent": last_result.summary.loss_percent,
                            "packets_lost": last_result.summary.packets_lost,
                            "packets_received": last_result.summary.packets_received,
                            "packets_sent": last_result.summary.packets_sent,
                        }
                    });
                    results.push(result_json);
                }
            }
        }

        let outer_data = serde_json::json!({
            "status": {
                "results": results,
                "timestamp": chrono::Utc::now().to_rfc3339()
            },
            "response_time": start_time.elapsed().as_nanos() as i64,
            "available": !results.is_empty()
        });

        let message_bytes = serde_json::to_vec(&outer_data).unwrap_or_else(|e| {
            error!("Failed to serialize test results: {e}");
            serde_json::to_vec(&serde_json::json!({
                "error": "Failed to serialize test results",
                "response_time": start_time.elapsed().as_nanos() as i64,
                "available": false
            }))
            .unwrap_or_default()
        });

        let response_time = start_time.elapsed().as_nanos() as i64;

        Ok(Response::new(monitoring::StatusResponse {
            available: !results.is_empty(),
            message: message_bytes,
            service_name: req.service_name,
            service_type: req.service_type,
            response_time,
            agent_id: req.agent_id,
        }))
    }
}

#[tonic::async_trait]
impl RPerfService for Arc<RPerfServiceImpl> {
    async fn run_test(
        &self,
        request: Request<TestRequest>,
    ) -> Result<Response<TestResponse>, Status> {
        (**self).run_test(request).await
    }

    async fn get_status(
        &self,
        request: Request<StatusRequest>,
    ) -> Result<Response<StatusResponse>, Status> {
        RPerfService::get_status(&**self, request).await
    }
}

#[tonic::async_trait]
impl AgentService for Arc<RPerfServiceImpl> {
    async fn get_status(
        &self,
        request: Request<monitoring::StatusRequest>,
    ) -> Result<Response<monitoring::StatusResponse>, Status> {
        debug!("AgentService::get_status invoked");
        let response = AgentService::get_status(&**self, request).await;
        debug!("AgentService::get_status returning: {:?}", response);
        response
    }
}

#[derive(Debug)]
pub struct ServerHandle {
    join_handle: JoinHandle<Result<()>>,
    poller_handle: JoinHandle<()>,
    pollers: Arc<RwLock<Vec<TargetPoller>>>,
}

impl ServerHandle {
    pub async fn stop(self) -> Result<()> {
        self.join_handle.abort();
        self.poller_handle.abort();
        for poller in self.pollers.write().await.iter_mut() {
            if let Err(e) = poller.stop().await {
                error!("Error stopping poller for {}: {}", poller.target_name(), e);
            }
        }
        match self.join_handle.await {
            Ok(result) => result,
            Err(e) if e.is_cancelled() => Ok(()),
            Err(e) => Err(anyhow::anyhow!("Server task failed: {}", e)),
        }
    }
}
