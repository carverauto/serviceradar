use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceStatus {
    pub service_name: String,
    pub available: bool,
    pub message: String,
    pub service_type: String,
    pub response_time: i64,
}

// Sysmon specific types
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CPUMetric {
    pub core_id: i32,
    pub usage_percent: f32,
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