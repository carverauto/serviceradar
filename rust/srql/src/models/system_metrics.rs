//! Host/system resource metric rows (CPU, memory, disk, process).

use chrono::{DateTime, Utc};
use diesel::prelude::*;
use serde::Serialize;

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::cpu_metrics, check_for_backend(diesel::pg::Pg))]
pub struct CpuMetricRow {
    pub timestamp: DateTime<Utc>,
    pub gateway_id: String,
    pub agent_id: Option<String>,
    pub host_id: Option<String>,
    pub core_id: Option<i32>,
    pub usage_percent: Option<f64>,
    pub frequency_hz: Option<f64>,
    pub label: Option<String>,
    pub cluster: Option<String>,
    pub device_id: Option<String>,
    pub partition: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl CpuMetricRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "gateway_id": self.gateway_id,
            "agent_id": self.agent_id,
            "host_id": self.host_id,
            "core_id": self.core_id,
            "usage_percent": self.usage_percent,
            "frequency_hz": self.frequency_hz,
            "label": self.label,
            "cluster": self.cluster,
            "uid": self.device_id,
            "partition": self.partition,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::memory_metrics, check_for_backend(diesel::pg::Pg))]
pub struct MemoryMetricRow {
    pub timestamp: DateTime<Utc>,
    pub gateway_id: Option<String>,
    pub agent_id: Option<String>,
    pub host_id: Option<String>,
    pub total_bytes: Option<i64>,
    pub used_bytes: Option<i64>,
    pub available_bytes: Option<i64>,
    pub usage_percent: Option<f64>,
    pub device_id: Option<String>,
    pub partition: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl MemoryMetricRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "gateway_id": self.gateway_id,
            "agent_id": self.agent_id,
            "host_id": self.host_id,
            "total_bytes": self.total_bytes,
            "used_bytes": self.used_bytes,
            "available_bytes": self.available_bytes,
            "usage_percent": self.usage_percent,
            "uid": self.device_id,
            "partition": self.partition,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::disk_metrics, check_for_backend(diesel::pg::Pg))]
pub struct DiskMetricRow {
    pub timestamp: DateTime<Utc>,
    pub gateway_id: Option<String>,
    pub agent_id: Option<String>,
    pub host_id: Option<String>,
    pub mount_point: Option<String>,
    pub device_name: Option<String>,
    pub total_bytes: Option<i64>,
    pub used_bytes: Option<i64>,
    pub available_bytes: Option<i64>,
    pub usage_percent: Option<f64>,
    pub device_id: Option<String>,
    pub partition: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl DiskMetricRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "gateway_id": self.gateway_id,
            "agent_id": self.agent_id,
            "host_id": self.host_id,
            "mount_point": self.mount_point,
            "device_name": self.device_name,
            "total_bytes": self.total_bytes,
            "used_bytes": self.used_bytes,
            "available_bytes": self.available_bytes,
            "usage_percent": self.usage_percent,
            "uid": self.device_id,
            "partition": self.partition,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::process_metrics, check_for_backend(diesel::pg::Pg))]
pub struct ProcessMetricRow {
    pub timestamp: DateTime<Utc>,
    pub gateway_id: Option<String>,
    pub agent_id: Option<String>,
    pub host_id: Option<String>,
    pub pid: Option<i32>,
    pub name: Option<String>,
    pub cpu_usage: Option<f32>,
    pub memory_usage: Option<i64>,
    pub status: Option<String>,
    pub start_time: Option<String>,
    pub device_id: Option<String>,
    pub partition: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl ProcessMetricRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "gateway_id": self.gateway_id,
            "agent_id": self.agent_id,
            "host_id": self.host_id,
            "pid": self.pid,
            "name": self.name,
            "cpu_usage": self.cpu_usage,
            "memory_usage": self.memory_usage,
            "status": self.status,
            "start_time": self.start_time,
            "uid": self.device_id,
            "partition": self.partition,
        })
    }
}
