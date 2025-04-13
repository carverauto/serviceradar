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

// server.rs

use std::fs;
use anyhow::{Context, Result};
use log::{debug, error, info};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::task::JoinHandle;
use tokio::time::{interval, Duration};
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
    pub fn new(collector: Arc<RwLock<MetricsCollector>>) -> Self {
        debug!("Creating SysmonService");
        Self { collector }
    }

    pub async fn start(&self, config: Arc<Config>) -> Result<ServerHandle> {
        let addr: SocketAddr = config.listen_addr.parse()
            .context("Failed to parse listen address")?;
        info!("Starting gRPC sysmon service on {}", addr);
        debug!("Server config: TLS={:?}", config.security);

        // Start periodic metrics collection
        let collector_for_task = Arc::clone(&self.collector);
        let poll_interval = config.poll_interval;
        let collection_handle = tokio::spawn(async move {
            let mut interval = interval(Duration::from_secs(poll_interval));
            loop {
                interval.tick().await;
                info!("Collecting system metrics periodically");
                let mut collector = collector_for_task.write().await;
                match collector.collect().await {
                    Ok(metrics) => {
                        debug!("Periodic collection successful: timestamp={}", metrics.timestamp);
                    }
                    Err(e) => {
                        error!("Periodic collection failed: {}", e);
                    }
                }
            }
        });

        let service = Arc::new(Self {
            collector: Arc::clone(&self.collector),
        });

        let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
        health_reporter
            .set_serving::<AgentServiceServer<Arc<SysmonService>>>()
            .await;
        debug!("Health service configured");

        let reflection_service = ReflectionBuilder::configure()
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
            .build()?;
        debug!("Reflection service configured");

        let mut server_builder = Server::builder();
        if let Some(security) = &config.security {
            if security.tls_enabled {
                debug!("Configuring TLS");
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

        debug!("Starting gRPC server");
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

        Ok(ServerHandle {
            join_handle: server_handle,
            collection_handle: Some(collection_handle),
        })
    }
}

#[tonic::async_trait]
impl AgentService for SysmonService {
    async fn get_status(
        &self,
        request: Request<monitoring::StatusRequest>,
    ) -> Result<Response<monitoring::StatusResponse>, Status> {
        let req = request.into_inner();
        info!(
            "Received GetStatus: service_name={}, service_type={}, details={}",
            req.service_name, req.service_type, req.details
        );
        debug!("Processing GetStatus request");

        let start_time = std::time::Instant::now();
        let collector = self.collector.read().await;
        let metrics = collector
            .get_latest_metrics()
            .await
            .ok_or_else(|| Status::unavailable("No metrics available yet"))?;

        debug!("Returning metrics with timestamp {}", metrics.timestamp);
        let message = serde_json::to_string(&metrics).map_err(|e| {
            error!("Failed to serialize metrics: {}", e);
            Status::internal(format!("Failed to serialize metrics: {}", e))
        })?;

        let response_time = start_time.elapsed().as_nanos() as i64;
        debug!("GetStatus response prepared: response_time={}ns", response_time);
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
        debug!("Delegating GetStatus to SysmonService");
        (**self).get_status(request).await
    }
}

#[derive(Debug)]
pub struct ServerHandle {
    join_handle: JoinHandle<Result<()>>,
    collection_handle: Option<JoinHandle<()>>,
}

impl ServerHandle {
    pub async fn stop(self) -> Result<()> {
        if let Some(collection_handle) = self.collection_handle {
            collection_handle.abort();
            info!("Collection task aborted");
        }
        self.join_handle.abort();
        match self.join_handle.await {
            Ok(result) => result,
            Err(e) if e.is_cancelled() => Ok(()),
            Err(e) => Err(anyhow::anyhow!("Server task failed: {}", e)),
        }
    }
}