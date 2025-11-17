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
    pub discovery_sources: Option<Vec<String>>,
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
        serde_json::json!({
            "device_id": self.device_id,
            "ip": self.ip,
            "poller_id": self.poller_id,
            "agent_id": self.agent_id,
            "hostname": self.hostname,
            "mac": self.mac,
            "discovery_sources": self.discovery_sources.unwrap_or_default(),
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

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::events)]
pub struct EventRow {
    pub event_timestamp: DateTime<Utc>,
    pub specversion: Option<String>,
    pub id: String,
    pub source: Option<String>,
    pub event_type: Option<String>,
    pub datacontenttype: Option<String>,
    pub subject: Option<String>,
    pub remote_addr: Option<String>,
    pub host: Option<String>,
    pub level: Option<i32>,
    pub severity: Option<String>,
    pub short_message: Option<String>,
    pub version: Option<String>,
    pub raw_data: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl EventRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "event_timestamp": self.event_timestamp,
            "specversion": self.specversion,
            "id": self.id,
            "source": self.source,
            "type": self.event_type,
            "datacontenttype": self.datacontenttype,
            "subject": self.subject,
            "remote_addr": self.remote_addr,
            "host": self.host,
            "level": self.level,
            "severity": self.severity,
            "short_message": self.short_message,
            "version": self.version,
            "raw_data": self.raw_data,
        })
    }
}

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::logs)]
pub struct LogRow {
    pub timestamp: DateTime<Utc>,
    pub trace_id: Option<String>,
    pub span_id: Option<String>,
    pub severity_text: Option<String>,
    pub severity_number: Option<i32>,
    pub body: Option<String>,
    pub service_name: Option<String>,
    pub service_version: Option<String>,
    pub service_instance: Option<String>,
    pub scope_name: Option<String>,
    pub scope_version: Option<String>,
    pub attributes: Option<String>,
    pub resource_attributes: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl LogRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "trace_id": self.trace_id,
            "span_id": self.span_id,
            "severity_text": self.severity_text,
            "severity_number": self.severity_number,
            "body": self.body,
            "service_name": self.service_name,
            "service_version": self.service_version,
            "service_instance": self.service_instance,
            "scope_name": self.scope_name,
            "scope_version": self.scope_version,
            "attributes": self.attributes.clone(),
            "resource_attributes": self.resource_attributes,
            "raw_data": self.attributes.unwrap_or_default(),
        })
    }
}
