use anyhow::Result;
use log::{debug, error, warn};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use clap::{App, ArgMatches, Arg};

use std::process::Command;
use std::time::Duration;

use crate::config::TargetConfig;
use crate::server::rperf_service::TestRequest;
use rperf::client;

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

fn parse_rperf_output(output: String, protocol: &str) -> Result<RPerfResult> {
    debug!("Parsing rperf output: '{}'", output);
    
    if output.trim().is_empty() {
        error!("Received empty output from rperf");
        return Ok(RPerfResult {
            success: false,
            error: Some("Empty output from rperf".to_string()),
            results_json: String::new(),
            summary: Default::default(),
        });
    }

    let json_value: serde_json::Value = match serde_json::from_str(&output) {
        Ok(value) => value,
        Err(e) => {
            error!("Failed to parse JSON: {}", e);
            error!("Raw output: {}", output);
            return Ok(RPerfResult {
                success: false,
                error: Some(format!("Failed to parse rperf JSON output: {}", e)),
                results_json: output,
                summary: Default::default(),
            });
        }
    };

    let summary_data = match &json_value["summary"] {
        serde_json::Value::Object(obj) => obj,
        _ => {
            error!("Invalid JSON structure: missing summary object");
            error!("JSON structure: {}", serde_json::to_string_pretty(&json_value).unwrap_or_default());
            return Ok(RPerfResult {
                success: false,
                error: Some("Invalid JSON structure: missing summary object".to_string()),
                results_json: output,
                summary: Default::default(),
            });
        }
    };

    let mut summary = RPerfSummary::default();

    if let Some(duration) = summary_data.get("duration_send").or_else(|| summary_data.get("duration_receive")) {
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
        results_json: output,
        summary,
    })
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
        debug!("Preparing to run rperf test to {}:{} with protocol {}", 
            self.target_address, self.port, self.protocol);

        let mut cmd = Command::new("./target/release/rperf"); // Adjust path as needed
        cmd.arg("--client").arg(&self.target_address)
        .arg("--port").arg(self.port.to_string())
        .arg("--format").arg("json")
        .arg("--time").arg(self.duration.to_string())
        .arg("--parallel").arg(self.parallel.to_string())
        .arg("--omit").arg(self.omit.to_string())
        .arg("--send-interval").arg(self.send_interval.to_string())
        .arg("--bandwidth").arg(self.bandwidth.to_string())
        .arg("--length").arg(self.length.to_string())
        .arg("--send-buffer").arg(self.send_buffer.to_string())
        .arg("--receive-buffer").arg(self.receive_buffer.to_string());

        if self.protocol == "udp" {
            cmd.arg("--udp");
        }
        if self.reverse {
            cmd.arg("--reverse");
        }
        if self.no_delay {
            cmd.arg("--no-delay");
        }

        debug!("Executing rperf command: {:?}", cmd);
        let output = tokio::time::timeout(Duration::from_secs((self.duration + 5.0) as u64), async {
            cmd.output()
        }).await.map_err(|_| anyhow::anyhow!("Test timed out"))?;

        match output {
            Ok(output) => {
                if output.status.success() {
                    let output_str = String::from_utf8(output.stdout)
                        .map_err(|e| anyhow::anyhow!("Failed to convert output to UTF-8: {}", e))?;
                    debug!("Raw output: {}", output_str);
                    parse_rperf_output(output_str, &self.protocol)
                } else {
                    let error_str = String::from_utf8_lossy(&output.stderr).to_string();
                    debug!("Command failed with error: {}", error_str);
                    Ok(RPerfResult {
                        success: false,
                        error: Some(error_str),
                        results_json: String::new(),
                        summary: Default::default(),
                    })
                }
            },
            Err(e) => Err(anyhow::anyhow!("Failed to execute rperf: {}", e)),
        }
    }
}