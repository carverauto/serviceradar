use anyhow::Result;
use log::{debug, error, info};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use std::vec::Vec;

use crate::config::TargetConfig;
use crate::server::rperf_service::TestRequest;
use rperf::{run_client_with_output, TestResults};

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

fn parse_rperf_output(output: &[u8], protocol: &str) -> Result<RPerfResult> {
    debug!("Parsing rperf output");

    if output.is_empty() {
        error!("Received empty output from rperf");
        return Ok(RPerfResult {
            success: false,
            error: Some("Empty output from rperf".to_string()),
            results_json: String::new(),
            summary: Default::default(),
        });
    }

    // Convert binary output to string
    let output_str = String::from_utf8_lossy(output).to_string();

    // Parse the JSON output
    let json_value: serde_json::Value = match serde_json::from_str(&output_str) {
        Ok(value) => value,
        Err(e) => {
            error!("Failed to parse JSON: {}", e);
            error!("Raw output: {}", output_str);
            return Ok(RPerfResult {
                success: false,
                error: Some(format!("Failed to parse rperf JSON output: {}", e)),
                results_json: output_str,
                summary: Default::default(),
            });
        }
    };

    // Extract the success status
    let success = match json_value.get("success") {
        Some(s) => s.as_bool().unwrap_or(false),
        None => false,
    };

    // If test failed, return early
    if !success {
        return Ok(RPerfResult {
            success: false,
            error: Some("Test reported failure".to_string()),
            results_json: output_str,
            summary: Default::default(),
        });
    }

    // Extract summary data
    let summary_data = match &json_value["summary"] {
        serde_json::Value::Object(obj) => obj,
        _ => {
            error!("Invalid JSON structure: missing summary object");
            error!("JSON structure: {}", serde_json::to_string_pretty(&json_value).unwrap_or_default());
            return Ok(RPerfResult {
                success: false,
                error: Some("Invalid JSON structure: missing summary object".to_string()),
                results_json: output_str,
                summary: Default::default(),
            });
        }
    };

    let mut summary = RPerfSummary::default();

    // Extract duration data
    if let Some(duration) = summary_data.get("duration_send").or_else(|| summary_data.get("duration_receive")) {
        summary.duration = duration.as_f64().unwrap_or_default();
    }

    // Extract bytes data
    if let Some(bytes) = summary_data.get("bytes_sent") {
        summary.bytes_sent = bytes.as_u64().unwrap_or_default();
    }

    if let Some(bytes) = summary_data.get("bytes_received") {
        summary.bytes_received = bytes.as_u64().unwrap_or_default();
    }

    // Calculate bits per second
    if summary.duration > 0.0 {
        let bytes = summary.bytes_received.max(summary.bytes_sent);
        summary.bits_per_second = (bytes as f64 * 8.0) / summary.duration;
    }

    // Extract UDP-specific data if applicable
    if protocol == "udp" {
        if let Some(packets) = summary_data.get("packets_sent") {
            summary.packets_sent = packets.as_u64().unwrap_or_default();
        }
        if let Some(packets) = summary_data.get("packets_received") {
            summary.packets_received = packets.as_u64().unwrap_or_default();
        }
        summary.packets_lost = summary.packets_sent.saturating_sub(summary.packets_received);
        if summary.packets_sent > 0 {
            summary.loss_percent = (summary.packets_lost as f64 / summary.packets_sent as f64) * 100.0;
        }
        if let Some(jitter) = summary_data.get("jitter_average") {
            summary.jitter_ms = jitter.as_f64().unwrap_or_default() * 1000.0;
        }
    }

    debug!("Parsed rperf result: {:?}", summary);
    Ok(RPerfResult {
        success: true,
        error: None,
        results_json: output_str,
        summary,
    })
}

#[derive(Debug)]
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
        debug!("Running rperf test to {}:{} with protocol {}", 
        self.target_address, self.port, self.protocol);

        let mut owned_args: Vec<String> = vec![
            "rperf".to_string(),  // Add program name
            // Combine --client and its value
            format!("--client={}", self.target_address),
            format!("--port={}", self.port),
            "--format=json".to_string(),
            format!("--time={}", self.duration),
            format!("--parallel={}", self.parallel),
            format!("--omit={}", self.omit),
            format!("--send-interval={}", self.send_interval),
            format!("--bandwidth={}", self.bandwidth),
        ];

        if self.length > 0 {
            owned_args.push(format!("--length={}", self.length));
        }

        owned_args.push(format!("--send-buffer={}", self.send_buffer));
        owned_args.push(format!("--receive-buffer={}", self.receive_buffer));

        if self.protocol == "udp" {
            owned_args.push("--udp".to_string());
        }
        if self.reverse {
            owned_args.push("--reverse".to_string());
        }
        if self.no_delay {
            owned_args.push("--no-delay".to_string());
        }

        let args: Vec<&str> = owned_args.iter().map(|s| s.as_str()).collect();
        debug!("Executing rperf with args: {:?}", args);

        let output_buffer = Arc::new(Mutex::new(Vec::new()));
        let output_clone = output_buffer.clone();

        let result = tokio::time::timeout(
            std::time::Duration::from_secs((self.duration + 10.0) as u64),
            tokio::task::spawn_blocking(move || {
                let args: Vec<&str> = owned_args.iter().map(|s| s.as_str()).collect();
                run_client_with_output(args, output_clone)
                    .map_err(|e| anyhow::anyhow!("rperf execution failed: {}", e))
            })
        ).await;

        match result {
            Ok(join_result) => match join_result {
                Ok(Ok(_)) => {
                    let output = output_buffer.lock().unwrap().clone();
                    parse_rperf_output(&output, &self.protocol)
                }
                Ok(Err(e)) => Ok(RPerfResult {
                    success: false,
                    error: Some(format!("rperf test execution failed: {}", e)),
                    results_json: String::new(),
                    summary: Default::default(),
                }),
                Err(e) => Ok(RPerfResult {
                    success: false,
                    error: Some(format!("Task panic: {}", e)),
                    results_json: String::new(),
                    summary: Default::default(),
                }),
            },
            Err(_) => {
                rperf::client::kill();
                Ok(RPerfResult {
                    success: false,
                    error: Some("Test timed out".to_string()),
                    results_json: String::new(),
                    summary: Default::default(),
                })
            }
        }
    }
}