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
 *
 */

// cmd/poller-ng/src/models/types.rs

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceStatus {
    pub service_name: String,
    pub available: bool,
    pub message: String,
    pub service_type: String,
    pub response_time: i64,
    pub agent_id: String,
}

// Sysmon specific types
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CPUMetric {
    pub core_id: i32,
    pub usage_percent: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frequency_hz: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cluster: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CPUClusterMetric {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frequency_hz: Option<f64>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DiskMetric {
    pub mount_point: String,
    pub used_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct MemoryMetric {
    pub used_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SysmonMetrics {
    pub timestamp: String,
    pub host_id: String,
    pub cpus: Vec<CPUMetric>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub clusters: Vec<CPUClusterMetric>,
    pub disks: Vec<DiskMetric>,
    pub memory: MemoryMetric,
}

// Rperf specific types
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct RperfSummary {
    pub bits_per_second: f64,
    pub bytes_received: u64,
    pub bytes_sent: u64,
    pub duration: f64,
    pub jitter_ms: Option<f64>,
    pub loss_percent: Option<f64>,
    pub packets_lost: Option<u64>,
    pub packets_received: Option<u64>,
    pub packets_sent: Option<u64>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct RperfResult {
    pub target: String,
    pub success: bool,
    pub error: Option<String>,
    pub summary: RperfSummary,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct RperfMetrics {
    pub results: Vec<RperfResult>,
}
