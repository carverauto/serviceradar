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
use prost::Message;
use serviceradar_metric_proto::{
    IngestIdentity, Metric, MetricBatch, MetricKind, MetricPoint, MetricResource,
    MetricTemporality, MetricValueType, StringMapEntry,
};
use std::fs;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::task::JoinHandle;
use tokio::time::{Duration, timeout};
use tonic::transport::Server;
use tonic::{Request, Response, Status};
use tonic_reflection::server::Builder as ReflectionBuilder;

use crate::config::{Config, SecurityMode};
use crate::poller::TargetPoller;
use crate::rperf::{RPerfResult, RPerfRunner};
use crate::server::monitoring::agent_service_server::{AgentService, AgentServiceServer};
use crate::spiffe;

const FILE_DESCRIPTOR_SET_RPERF: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/rperf_descriptor.bin"));
const FILE_DESCRIPTOR_SET_MONITORING: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/monitoring_descriptor.bin"));
const METRIC_SCHEMA_VERSION: &str = "serviceradar.metric.v1";

pub mod rperf_service {
    tonic::include_proto!("rperf");
}

pub mod monitoring {
    tonic::include_proto!("monitoring");
}

use rperf_service::{
    StatusRequest, StatusResponse, TestRequest, TestResponse, TestSummary,
    r_perf_service_server::{RPerfService, RPerfServiceServer},
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

        let (health_reporter, health_service) = tonic_health::server::health_reporter();
        health_reporter
            .set_serving::<RPerfServiceServer<RPerfServiceImpl>>()
            .await;
        health_reporter
            .set_serving::<AgentServiceServer<Arc<RPerfServiceImpl>>>()
            .await;

        let reflection_service = ReflectionBuilder::configure()
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_RPERF)
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
            .build_v1()?;

        let mut server_builder = Server::builder();

        let mut spiffe_guard: Option<spiffe::SpiffeSourceGuard> = None;
        if let Some(security) = &self.config.security {
            match security.mode {
                SecurityMode::None => {}
                SecurityMode::Mtls => {
                    let tls = security
                        .tls
                        .as_ref()
                        .context("security.tls configuration is required for mTLS mode")?;

                    let cert_path = security.resolve_path(
                        tls.cert_file
                            .as_deref()
                            .context("security.tls.cert_file is required for mTLS mode")?,
                    );
                    let key_path = security.resolve_path(
                        tls.key_file
                            .as_deref()
                            .context("security.tls.key_file is required for mTLS mode")?,
                    );
                    let ca_path = security.resolve_path(
                        tls.ca_file
                            .as_deref()
                            .context("security.tls.ca_file is required for mTLS mode")?,
                    );

                    let cert = fs::read(&cert_path).with_context(|| {
                        format!("Failed to read certificate file at {cert_path:?}")
                    })?;
                    let key = fs::read(&key_path)
                        .with_context(|| format!("Failed to read key file at {key_path:?}"))?;
                    let ca = fs::read(&ca_path).with_context(|| {
                        format!("Failed to read CA certificate file at {ca_path:?}")
                    })?;

                    let identity = tonic::transport::Identity::from_pem(cert, key);
                    let ca = tonic::transport::Certificate::from_pem(ca);

                    let tls_config = tonic::transport::ServerTlsConfig::new()
                        .identity(identity)
                        .client_ca_root(ca);
                    debug!("TLS config created");
                    server_builder = server_builder.tls_config(tls_config)?;
                    info!("TLS configured with mTLS enabled");
                }
                SecurityMode::Spiffe => {
                    let workload_socket = security
                        .workload_socket
                        .as_deref()
                        .context("security.workload_socket is required for spiffe mode")?;
                    let trust_domain = security
                        .trust_domain
                        .as_deref()
                        .context("security.trust_domain is required for spiffe mode")?;

                    let credentials =
                        spiffe::load_server_credentials(workload_socket, trust_domain).await?;
                    let (identity, client_ca, guard) = credentials.into_parts();
                    let tls = tonic::transport::ServerTlsConfig::new()
                        .identity(identity)
                        .client_ca_root(client_ca);
                    spiffe_guard = Some(guard);
                    server_builder = server_builder.tls_config(tls)?;
                    info!("TLS configured with SPIFFE mode");
                }
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
            spiffe_guard,
        })
    }
}

struct RPerfServiceImpl {
    target_pollers: Arc<RwLock<Vec<TargetPoller>>>,
}

struct RPerfMetricSample<'a> {
    target: &'a str,
    result: &'a RPerfResult,
}

fn poller_matches_request(poller: &TargetPoller, req: &monitoring::StatusRequest) -> bool {
    (!req.details.is_empty() && poller.target_name() == req.details)
        || (!req.service_name.is_empty() && poller.target_name() == req.service_name)
        || (req.details.is_empty() && req.service_name.is_empty())
}

fn rperf_metric_batch(
    samples: &[RPerfMetricSample<'_>],
    req: &monitoring::StatusRequest,
) -> Option<MetricBatch> {
    if samples.is_empty() {
        return None;
    }

    let observed_at = chrono::Utc::now().timestamp_nanos_opt()? as u64;
    let mut metrics = vec![
        rperf_gauge_metric("rperf.available", "1"),
        rperf_gauge_metric("rperf.duration_seconds", "s"),
        rperf_gauge_metric("rperf.bytes_sent", "By"),
        rperf_gauge_metric("rperf.bytes_received", "By"),
        rperf_gauge_metric("rperf.bits_per_second", "bit/s"),
        rperf_gauge_metric("rperf.packets_sent", "{packet}"),
        rperf_gauge_metric("rperf.packets_received", "{packet}"),
        rperf_gauge_metric("rperf.packets_lost", "{packet}"),
        rperf_gauge_metric("rperf.loss_percent", "%"),
        rperf_gauge_metric("rperf.jitter_ms", "ms"),
    ];

    for sample in samples {
        let attrs = rperf_attrs(sample.target, sample.result);
        push_point(
            &mut metrics[0],
            bool_value(sample.result.success),
            observed_at,
            &attrs,
        );

        if sample.result.success {
            let summary = &sample.result.summary;
            push_point(&mut metrics[1], summary.duration, observed_at, &attrs);
            push_point(
                &mut metrics[2],
                summary.bytes_sent as f64,
                observed_at,
                &attrs,
            );
            push_point(
                &mut metrics[3],
                summary.bytes_received as f64,
                observed_at,
                &attrs,
            );
            push_point(
                &mut metrics[4],
                summary.bits_per_second,
                observed_at,
                &attrs,
            );
            push_point(
                &mut metrics[5],
                summary.packets_sent as f64,
                observed_at,
                &attrs,
            );
            push_point(
                &mut metrics[6],
                summary.packets_received as f64,
                observed_at,
                &attrs,
            );
            push_point(
                &mut metrics[7],
                summary.packets_lost as f64,
                observed_at,
                &attrs,
            );
            push_point(&mut metrics[8], summary.loss_percent, observed_at, &attrs);
            push_point(&mut metrics[9], summary.jitter_ms, observed_at, &attrs);
        }
    }

    metrics.retain(|metric| !metric.points.is_empty());

    Some(MetricBatch {
        schema_version: METRIC_SCHEMA_VERSION.to_owned(),
        resource: Some(MetricResource {
            agent_id: req.agent_id.clone(),
            gateway_id: req.gateway_id.clone(),
            service_name: if req.service_name.is_empty() {
                "rperf".to_owned()
            } else {
                req.service_name.clone()
            },
            service_type: if req.service_type.is_empty() {
                "rperf".to_owned()
            } else {
                req.service_type.clone()
            },
            ..Default::default()
        }),
        ingest_identity: Some(IngestIdentity {
            source: "rperf-metrics".to_owned(),
            payload_kind: METRIC_SCHEMA_VERSION.to_owned(),
            producer_id: req.agent_id.clone(),
            producer_kind: "rperf-checker".to_owned(),
            attested_by: req.gateway_id.clone(),
            ..Default::default()
        }),
        emitted_at_unix_nano: observed_at,
        metrics,
        ..Default::default()
    })
}

fn rperf_gauge_metric(name: &str, unit: &str) -> Metric {
    Metric {
        name: name.to_owned(),
        metric_type: "rperf".to_owned(),
        kind: MetricKind::Gauge as i32,
        temporality: MetricTemporality::Unspecified as i32,
        unit: unit.to_owned(),
        tags: entries(&[("metric_family", "rperf")]),
        ..Default::default()
    }
}

fn push_point(metric: &mut Metric, value: f64, observed_at: u64, attrs: &[StringMapEntry]) {
    metric.points.push(MetricPoint {
        value,
        raw_value: value.to_string(),
        raw_value_type: MetricValueType::Double as i32,
        observed_at_unix_nano: observed_at,
        attributes: attrs.to_vec(),
        ..Default::default()
    });
}

fn bool_value(value: bool) -> f64 {
    if value { 1.0 } else { 0.0 }
}

fn rperf_attrs(target: &str, result: &RPerfResult) -> Vec<StringMapEntry> {
    let mut attrs = entries(&[("target", target)]);
    if let Some(error) = result.error.as_deref().filter(|value| !value.is_empty()) {
        attrs.push(StringMapEntry {
            key: "error".to_owned(),
            value: error.to_owned(),
        });
    }

    attrs
}

fn entries(values: &[(&str, &str)]) -> Vec<StringMapEntry> {
    values
        .iter()
        .filter_map(|(key, value)| {
            let key = key.trim();
            let value = value.trim();
            if key.is_empty() || value.is_empty() {
                None
            } else {
                Some(StringMapEntry {
                    key: key.to_owned(),
                    value: value.to_owned(),
                })
            }
        })
        .collect()
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
                    gateway_id: req.gateway_id,
                }));
            }
        };

        let mut metric_samples = Vec::new();
        for poller in pollers.iter() {
            if poller_matches_request(poller, &req)
                && let Some(last_result) = &poller.last_result
            {
                metric_samples.push(RPerfMetricSample {
                    target: poller.target_name(),
                    result: last_result,
                });
            }
        }

        if let Some(batch) = rperf_metric_batch(&metric_samples, &req) {
            let response_time = start_time.elapsed().as_nanos() as i64;

            return Ok(Response::new(monitoring::StatusResponse {
                available: !metric_samples.is_empty(),
                message: batch.encode_to_vec(),
                service_name: req.service_name,
                service_type: req.service_type,
                response_time,
                agent_id: req.agent_id,
                gateway_id: req.gateway_id,
            }));
        }

        let mut results = Vec::new();
        for poller in pollers.iter() {
            if poller_matches_request(poller, &req)
                && let Some(last_result) = &poller.last_result
            {
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
            gateway_id: req.gateway_id,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rperf::RPerfSummary;

    #[test]
    fn rperf_metric_batch_encodes_canonical_metrics() {
        let result = RPerfResult {
            success: true,
            error: None,
            results_json: String::new(),
            summary: RPerfSummary {
                duration: 10.0,
                bytes_sent: 1_000,
                bytes_received: 2_000,
                bits_per_second: 1_600.0,
                packets_sent: 10,
                packets_received: 9,
                packets_lost: 1,
                loss_percent: 10.0,
                jitter_ms: 0.5,
            },
        };
        let req = monitoring::StatusRequest {
            agent_id: "agent-1".to_owned(),
            gateway_id: "gateway-1".to_owned(),
            service_name: "rperf".to_owned(),
            service_type: "rperf".to_owned(),
            details: String::new(),
            port: 0,
        };

        let batch = rperf_metric_batch(
            &[RPerfMetricSample {
                target: "wan-test",
                result: &result,
            }],
            &req,
        )
        .expect("metric batch");

        assert_eq!(batch.schema_version, METRIC_SCHEMA_VERSION);
        assert_eq!(batch.resource.as_ref().unwrap().service_type, "rperf");
        assert_eq!(
            batch.ingest_identity.as_ref().unwrap().source,
            "rperf-metrics"
        );
        assert!(
            batch
                .metrics
                .iter()
                .any(|metric| metric.name == "rperf.bits_per_second"
                    && metric.points[0].value == 1_600.0)
        );

        let decoded = MetricBatch::decode(batch.encode_to_vec().as_slice()).expect("decode batch");
        assert_eq!(decoded.metrics.len(), batch.metrics.len());
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
    #[allow(dead_code)]
    spiffe_guard: Option<spiffe::SpiffeSourceGuard>,
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
