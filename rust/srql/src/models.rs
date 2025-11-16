//! Data models for CNPG-backed SRQL queries.

use chrono::{DateTime, Utc};
use diesel::prelude::*;
use serde::Serialize;

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::unified_devices)]
pub struct DeviceRow {
    pub device_id: String,
    pub ip: Option<String>,
    pub poller_id: Option<String>,
    pub agent_id: Option<String>,
    pub hostname: Option<String>,
    pub mac: Option<String>,
    pub discovery_sources: Option<Vec<Option<String>>>,
    pub is_available: bool,
    pub first_seen: DateTime<Utc>,
    pub last_seen: DateTime<Utc>,
    pub metadata: Option<serde_json::Value>,
    pub device_type: Option<String>,
    pub service_type: Option<String>,
    pub service_status: Option<String>,
    pub last_heartbeat: Option<DateTime<Utc>>,
    pub os_info: Option<String>,
    pub version_info: Option<String>,
}

impl DeviceRow {
    pub fn into_json(self) -> serde_json::Value {
        let discovery_sources = self
            .discovery_sources
            .unwrap_or_default()
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();

        serde_json::json!({
            "_tp_time": self.last_seen,
            "device_id": self.device_id,
            "ip": self.ip,
            "poller_id": self.poller_id,
            "agent_id": self.agent_id,
            "hostname": self.hostname,
            "mac": self.mac,
            "discovery_sources": discovery_sources,
            "is_available": self.is_available,
            "first_seen": self.first_seen,
            "last_seen": self.last_seen,
            "metadata": self.metadata.unwrap_or(serde_json::json!({})),
            "device_type": self.device_type,
            "service_type": self.service_type,
            "service_status": self.service_status,
            "last_heartbeat": self.last_heartbeat,
            "os_info": self.os_info,
            "version_info": self.version_info,
        })
    }
}
