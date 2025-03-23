use anyhow::{Context, Result};
use log::debug;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

use crate::config::TargetConfig;
use crate::server::rperf_service::TestRequest;

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct RPerfSummary {
    pub duration: f64,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    pub bits_per_second: f64,
    pub packets_sent: u64,
    pub packets_received: u64,
    pub packets_lost: u64,
    pub loss_percent: f64,
    pub jitter_ms: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RPerfResult {
    pub success: bool,
    pub error: Option<String>,
    pub results_json: String,
    pub summary: RPerfSummary,
}

pub struct RPerfRunner {
    target_address: String,
    port: u16,
    protocol: String,
    reverse: bool,
    bandwidth: u64,
    duration: f64,
    parallel: u32,
    length: u32,
    omit: u32,
    no_delay: bool,
    send_buffer: u32,
    receive_buffer: u32,
    send_interval: f64,
}

impl RPerfRunner {
    pub fn from_grpc_request(req: TestRequest) -> Self {
        Self {
            target_address: req.target_address,
            port: req.port as u16,
            protocol: req.protocol,
            reverse: req.reverse,
            bandwidth: req.bandwidth,
            duration: req.duration,
            parallel: req.parallel,
            length: req.length,
            omit: req.omit,
            no_delay: req.no_delay,
            send_buffer: req.send_buffer,
            receive_buffer: req.receive_buffer,
            send_interval: req.send_interval,
        }
    }

    pub fn from_target_config(config: &TargetConfig) -> Self {
        Self {
            target_address: config.address.clone(),
            port: config.port,
            protocol: config.protocol.clone(),
            reverse: config.reverse,
            bandwidth: config.bandwidth,
            duration: config.duration,
            parallel: config.parallel,
            length: config.length,
            omit: config.omit,
            no_delay: config.no_delay,
            send_buffer: config.send_buffer,
            receive_buffer: config.receive_buffer,
            send_interval: config.send_interval,
        }
    }

    pub async fn run_test(&self) -> Result<RPerfResult> {
        // Clone all necessary data to own it in the closure
        let target_address = self.target_address.clone();
        let port_str = self.port.to_string();
        let duration_str = self.duration.to_string();
        let parallel_str = self.parallel.to_string();
        let omit_str = self.omit.to_string();
        let send_interval_str = self.send_interval.to_string();
        let bandwidth_str = self.bandwidth.to_string();
        let length_str = self.length.to_string();
        let send_buffer_str = self.send_buffer.to_string();
        let receive_buffer_str = self.receive_buffer.to_string();
        let protocol = self.protocol.clone();
        let reverse = self.reverse;
        let no_delay = self.no_delay;
        let send_interval = self.send_interval;
        let bandwidth = self.bandwidth;
        let length = self.length;
        let send_buffer = self.send_buffer;
        let receive_buffer = self.receive_buffer;

        let output = Arc::new(Mutex::new(Vec::new()));
        let output_clone = output.clone();

        let result = tokio::task::spawn_blocking(move || -> Result<String, anyhow::Error> {
            let mut args = vec![
                "rperf",
                "--client",
                &target_address,
                "--port",
                &port_str,
                "--format",
                "json",
                "--time",
                &duration_str,
                "--parallel",
                &parallel_str,
                "--omit",
                &omit_str,
            ];

            if protocol == "udp" {
                args.push("--udp");
            }
            if reverse {
                args.push("--reverse");
            }
            if no_delay {
                args.push("--no-delay");
            }
            if send_interval > 0.0 {
                args.extend_from_slice(&["--send-interval", &send_interval_str]);
            }
            if bandwidth > 0 {
                args.extend_from_slice(&["--bandwidth", &bandwidth_str]);
            }
            if length > 0 {
                args.extend_from_slice(&["--length", &length_str]);
            }
            if send_buffer > 0 {
                args.extend_from_slice(&["--send-buffer", &send_buffer_str]);
            }
            if receive_buffer > 0 {
                args.extend_from_slice(&["--receive-buffer", &receive_buffer_str]);
            }

            debug!("Running rperf test with args: {:?}", args);

            rperf::run_client_with_output(args, output_clone)
                .map_err(|e| anyhow::anyhow!("rperf execution failed: {}", e))?;
            let output_str = String::from_utf8(output.lock().unwrap().clone())
                .map_err(|e| anyhow::anyhow!("Failed to convert output to UTF-8: {}", e))?;
            Ok(output_str)
        })
        .await
        .context("Failed to spawn blocking task")?
        .context("rperf client execution failed")?;

        self.parse_rperf_output(&result)
    }

    fn parse_rperf_output(&self, output: &str) -> Result<RPerfResult> {
        let json_value: serde_json::Value = serde_json::from_str(output)
            .context("Failed to parse rperf JSON output")?;

        let summary_data = match &json_value["summary"] {
            serde_json::Value::Object(obj) => obj,
            _ => {
                return Ok(RPerfResult {
                    success: false,
                    error: Some("Invalid JSON structure: missing summary object".to_string()),
                    results_json: output.to_string(),
                    summary: Default::default(),
                });
            }
        };

        let mut summary = RPerfSummary::default();

        if let Some(duration) = summary_data
            .get("duration_send")
            .or_else(|| summary_data.get("duration_receive"))
        {
            summary.duration = duration.as_f64().unwrap_or_default();
        }
        if let Some(bytes) = summary_data.get("bytes_sent") {
            summary.bytes_sent = bytes.as_u64().unwrap_or_default();
        }
        if let Some(bytes) = summary_data.get("bytes_received") {
            summary.bytes_received = bytes.as_u64().unwrap_or_default();
        }
        if summary.duration > 0.0 {
            let bytes = summary.bytes_received.max(summary.bytes_sent);
            summary.bits_per_second = (bytes as f64 * 8.0) / summary.duration;
        }
        if self.protocol == "udp" {
            if let Some(packets) = summary_data.get("packets_sent") {
                summary.packets_sent = packets.as_u64().unwrap_or_default();
            }
            if let Some(packets) = summary_data.get("packets_received") {
                summary.packets_received = packets.as_u64().unwrap_or_default();
            }
            summary.packets_lost = summary.packets_sent.saturating_sub(summary.packets_received);
            if summary.packets_sent > 0 {
                summary.loss_percent =
                    (summary.packets_lost as f64 / summary.packets_sent as f64) * 100.0;
            }
            if let Some(jitter) = summary_data.get("jitter_average") {
                summary.jitter_ms = jitter.as_f64().unwrap_or_default() * 1000.0;
            }
        }

        Ok(RPerfResult {
            success: true,
            error: None,
            results_json: output.to_string(),
            summary,
        })
    }
}