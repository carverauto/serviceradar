//! Data models for CNPG-backed SRQL queries.

use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::prelude::*;
use diesel::sql_types::{Array, Float8, Int4, Int8, Nullable, Text, Timestamptz};
use serde::Serialize;

/// OCSF-aligned device row (OCSF v1.7.0 Device object)
#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::ocsf_devices)]
pub struct DeviceRow {
    // OCSF Core Identity
    pub uid: String,
    pub type_id: i32,
    pub device_type: Option<String>,
    pub name: Option<String>,
    pub hostname: Option<String>,
    pub ip: Option<String>,
    pub mac: Option<String>,

    // OCSF Extended Identity
    pub uid_alt: Option<String>,
    pub vendor_name: Option<String>,
    pub model: Option<String>,
    pub domain: Option<String>,
    pub zone: Option<String>,
    pub subnet_uid: Option<String>,
    pub vlan_uid: Option<String>,
    pub region: Option<String>,

    // OCSF Temporal
    pub first_seen_time: Option<DateTime<Utc>>,
    pub last_seen_time: Option<DateTime<Utc>>,
    pub created_time: DateTime<Utc>,
    pub modified_time: DateTime<Utc>,

    // OCSF Risk and Compliance
    pub risk_level_id: Option<i32>,
    pub risk_level: Option<String>,
    pub risk_score: Option<i32>,
    pub is_managed: Option<bool>,
    pub is_compliant: Option<bool>,
    pub is_trusted: Option<bool>,

    // OCSF Nested Objects (JSONB)
    pub os: Option<serde_json::Value>,
    pub hw_info: Option<serde_json::Value>,
    pub network_interfaces: Option<serde_json::Value>,
    pub owner: Option<serde_json::Value>,
    pub org: Option<serde_json::Value>,
    pub groups: Option<serde_json::Value>,
    pub agent_list: Option<serde_json::Value>,

    // ServiceRadar-specific fields
    pub poller_id: Option<String>,
    pub agent_id: Option<String>,
    pub discovery_sources: Option<Vec<String>>,
    pub is_available: Option<bool>,
    pub metadata: Option<serde_json::Value>,
}

impl DeviceRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            // OCSF Core Identity
            "uid": self.uid,
            "type_id": self.type_id,
            "type": self.device_type,
            "device_type": self.device_type,  // Alias for backward compatibility
            "name": self.name,
            "hostname": self.hostname,
            "ip": self.ip,
            "mac": self.mac,

            // OCSF Extended Identity
            "uid_alt": self.uid_alt,
            "vendor_name": self.vendor_name,
            "model": self.model,
            "domain": self.domain,
            "zone": self.zone,
            "subnet_uid": self.subnet_uid,
            "vlan_uid": self.vlan_uid,
            "region": self.region,

            // OCSF Temporal
            "first_seen_time": self.first_seen_time,
            "last_seen_time": self.last_seen_time,
            "first_seen": self.first_seen_time,  // Alias for backward compatibility
            "last_seen": self.last_seen_time,    // Alias for backward compatibility
            "created_time": self.created_time,
            "modified_time": self.modified_time,

            // OCSF Risk and Compliance
            "risk_level_id": self.risk_level_id,
            "risk_level": self.risk_level,
            "risk_score": self.risk_score,
            "is_managed": self.is_managed,
            "is_compliant": self.is_compliant,
            "is_trusted": self.is_trusted,

            // OCSF Nested Objects
            "os": self.os,
            "hw_info": self.hw_info,
            "network_interfaces": self.network_interfaces,
            "owner": self.owner,
            "org": self.org,
            "groups": self.groups,
            "agent_list": self.agent_list,

            // ServiceRadar-specific
            "poller_id": self.poller_id,
            "agent_id": self.agent_id,
            "discovery_sources": self.discovery_sources.unwrap_or_default(),
            "is_available": self.is_available.unwrap_or(false),
            "metadata": self.metadata.unwrap_or(serde_json::json!({})),
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

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::discovered_interfaces)]
pub struct DiscoveredInterfaceRow {
    pub timestamp: DateTime<Utc>,
    pub agent_id: Option<String>,
    pub poller_id: Option<String>,
    pub device_ip: Option<String>,
    pub device_id: Option<String>,
    pub if_index: Option<i32>,
    pub if_name: Option<String>,
    pub if_descr: Option<String>,
    pub if_alias: Option<String>,
    pub if_speed: Option<i64>,
    pub if_phys_address: Option<String>,
    pub ip_addresses: Option<Vec<String>>,
    pub if_admin_status: Option<i32>,
    pub if_oper_status: Option<i32>,
    pub metadata: Option<serde_json::Value>,
    pub created_at: DateTime<Utc>,
}

impl DiscoveredInterfaceRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "agent_id": self.agent_id,
            "poller_id": self.poller_id,
            "device_ip": self.device_ip,
            "device_id": self.device_id,
            "if_index": self.if_index,
            "if_name": self.if_name,
            "if_descr": self.if_descr,
            "if_alias": self.if_alias,
            "if_speed": self.if_speed,
            "if_phys_address": self.if_phys_address,
            "ip_addresses": self.ip_addresses.unwrap_or_default(),
            "if_admin_status": self.if_admin_status,
            "if_oper_status": self.if_oper_status,
            "metadata": self.metadata.unwrap_or(serde_json::json!({})),
            "created_at": self.created_at,
        })
    }
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
#[diesel(table_name = crate::schema::device_updates)]
pub struct DeviceUpdateRow {
    pub observed_at: DateTime<Utc>,
    pub agent_id: String,
    pub poller_id: String,
    pub partition: String,
    pub device_id: String,
    pub discovery_source: String,
    pub ip: Option<String>,
    pub mac: Option<String>,
    pub hostname: Option<String>,
    pub available: Option<bool>,
    pub metadata: Option<serde_json::Value>,
    pub created_at: DateTime<Utc>,
}

impl DeviceUpdateRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "observed_at": self.observed_at,
            "agent_id": self.agent_id,
            "poller_id": self.poller_id,
            "partition": self.partition,
            "device_id": self.device_id,
            "discovery_source": self.discovery_source,
            "ip": self.ip,
            "mac": self.mac,
            "hostname": self.hostname,
            "available": self.available,
            "metadata": self.metadata.unwrap_or(serde_json::json!({})),
            "created_at": self.created_at,
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

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::otel_traces)]
pub struct TraceSpanRow {
    pub timestamp: DateTime<Utc>,
    pub trace_id: Option<String>,
    pub span_id: String,
    pub parent_span_id: Option<String>,
    pub name: Option<String>,
    pub kind: Option<i32>,
    pub start_time_unix_nano: Option<i64>,
    pub end_time_unix_nano: Option<i64>,
    pub service_name: Option<String>,
    pub service_version: Option<String>,
    pub service_instance: Option<String>,
    pub scope_name: Option<String>,
    pub scope_version: Option<String>,
    pub status_code: Option<i32>,
    pub status_message: Option<String>,
    pub attributes: Option<String>,
    pub resource_attributes: Option<String>,
    pub events: Option<String>,
    pub links: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl TraceSpanRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "trace_id": self.trace_id,
            "span_id": self.span_id,
            "parent_span_id": self.parent_span_id,
            "name": self.name,
            "kind": self.kind,
            "start_time_unix_nano": self.start_time_unix_nano,
            "end_time_unix_nano": self.end_time_unix_nano,
            "service_name": self.service_name,
            "service_version": self.service_version,
            "service_instance": self.service_instance,
            "scope_name": self.scope_name,
            "scope_version": self.scope_version,
            "status_code": self.status_code,
            "status_message": self.status_message,
            "attributes": self.attributes.clone(),
            "resource_attributes": self.resource_attributes,
            "events": self.events,
            "links": self.links,
            "raw_data": self.attributes.unwrap_or_default(),
        })
    }
}

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::service_status)]
pub struct ServiceStatusRow {
    pub timestamp: DateTime<Utc>,
    pub poller_id: String,
    pub agent_id: Option<String>,
    pub service_name: String,
    pub service_type: Option<String>,
    pub available: bool,
    pub message: Option<String>,
    pub details: Option<String>,
    pub partition: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl ServiceStatusRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "last_seen": self.timestamp,
            "created_at": self.created_at,
            "poller_id": self.poller_id,
            "agent_id": self.agent_id,
            "service_name": self.service_name,
            "service_type": self.service_type,
            "name": self.service_name,
            "type": self.service_type,
            "available": self.available,
            "message": self.message,
            "details": self.details,
            "partition": self.partition,
        })
    }
}

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::pollers)]
pub struct PollerRow {
    pub poller_id: String,
    pub component_id: Option<String>,
    pub registration_source: Option<String>,
    pub status: Option<String>,
    pub spiffe_identity: Option<String>,
    pub first_registered: Option<DateTime<Utc>>,
    pub first_seen: Option<DateTime<Utc>>,
    pub last_seen: Option<DateTime<Utc>>,
    pub metadata: Option<serde_json::Value>,
    pub created_by: Option<String>,
    pub is_healthy: Option<bool>,
    pub agent_count: Option<i32>,
    pub checker_count: Option<i32>,
    pub updated_at: Option<DateTime<Utc>>,
}

impl PollerRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "poller_id": self.poller_id,
            "component_id": self.component_id,
            "registration_source": self.registration_source,
            "status": self.status,
            "spiffe_identity": self.spiffe_identity,
            "first_registered": self.first_registered,
            "first_seen": self.first_seen,
            "last_seen": self.last_seen,
            "metadata": self.metadata.unwrap_or(serde_json::json!({})),
            "created_by": self.created_by,
            "is_healthy": self.is_healthy,
            "agent_count": self.agent_count.unwrap_or(0),
            "checker_count": self.checker_count.unwrap_or(0),
            "updated_at": self.updated_at,
        })
    }
}

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::otel_metrics)]
pub struct OtelMetricRow {
    pub timestamp: DateTime<Utc>,
    pub trace_id: Option<String>,
    pub span_id: Option<String>,
    pub service_name: Option<String>,
    pub span_name: Option<String>,
    pub span_kind: Option<String>,
    pub duration_ms: Option<f64>,
    pub duration_seconds: Option<f64>,
    pub metric_type: Option<String>,
    pub http_method: Option<String>,
    pub http_route: Option<String>,
    pub http_status_code: Option<String>,
    pub grpc_service: Option<String>,
    pub grpc_method: Option<String>,
    pub grpc_status_code: Option<String>,
    pub is_slow: Option<bool>,
    pub component: Option<String>,
    pub level: Option<String>,
    pub unit: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl OtelMetricRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "trace_id": self.trace_id,
            "span_id": self.span_id,
            "service_name": self.service_name,
            "span_name": self.span_name,
            "span_kind": self.span_kind,
            "duration_ms": self.duration_ms,
            "duration_seconds": self.duration_seconds,
            "metric_type": self.metric_type,
            "http_method": self.http_method,
            "http_route": self.http_route,
            "http_status_code": self.http_status_code,
            "grpc_service": self.grpc_service,
            "grpc_method": self.grpc_method,
            "grpc_status_code": self.grpc_status_code,
            "is_slow": self.is_slow,
            "component": self.component,
            "level": self.level,
            "unit": self.unit,
        })
    }
}

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::timeseries_metrics)]
pub struct TimeseriesMetricRow {
    pub timestamp: DateTime<Utc>,
    pub poller_id: String,
    pub agent_id: Option<String>,
    pub metric_name: String,
    pub metric_type: String,
    pub device_id: Option<String>,
    pub value: f64,
    pub unit: Option<String>,
    pub tags: Option<serde_json::Value>,
    pub partition: Option<String>,
    pub scale: Option<f64>,
    pub is_delta: Option<bool>,
    pub target_device_ip: Option<String>,
    pub if_index: Option<i32>,
    pub metadata: Option<serde_json::Value>,
    pub created_at: DateTime<Utc>,
}

impl TimeseriesMetricRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "poller_id": self.poller_id,
            "agent_id": self.agent_id,
            "metric_name": self.metric_name,
            "metric_type": self.metric_type,
            "device_id": self.device_id,
            "value": self.value,
            "unit": self.unit,
            "tags": self.tags,
            "partition": self.partition,
            "scale": self.scale,
            "is_delta": self.is_delta,
            "target_device_ip": self.target_device_ip,
            "if_index": self.if_index,
            "metadata": self.metadata,
            "created_at": self.created_at,
        })
    }
}

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::cpu_metrics)]
pub struct CpuMetricRow {
    pub timestamp: DateTime<Utc>,
    pub poller_id: String,
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
            "poller_id": self.poller_id,
            "agent_id": self.agent_id,
            "host_id": self.host_id,
            "core_id": self.core_id,
            "usage_percent": self.usage_percent,
            "frequency_hz": self.frequency_hz,
            "label": self.label,
            "cluster": self.cluster,
            "device_id": self.device_id,
            "partition": self.partition,
        })
    }
}

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::memory_metrics)]
pub struct MemoryMetricRow {
    pub timestamp: DateTime<Utc>,
    pub poller_id: Option<String>,
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
            "poller_id": self.poller_id,
            "agent_id": self.agent_id,
            "host_id": self.host_id,
            "total_bytes": self.total_bytes,
            "used_bytes": self.used_bytes,
            "available_bytes": self.available_bytes,
            "usage_percent": self.usage_percent,
            "device_id": self.device_id,
            "partition": self.partition,
        })
    }
}

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::disk_metrics)]
pub struct DiskMetricRow {
    pub timestamp: DateTime<Utc>,
    pub poller_id: Option<String>,
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
            "poller_id": self.poller_id,
            "agent_id": self.agent_id,
            "host_id": self.host_id,
            "mount_point": self.mount_point,
            "device_name": self.device_name,
            "total_bytes": self.total_bytes,
            "used_bytes": self.used_bytes,
            "available_bytes": self.available_bytes,
            "usage_percent": self.usage_percent,
            "device_id": self.device_id,
            "partition": self.partition,
        })
    }
}

#[derive(Debug, Clone, Queryable, Serialize)]
#[diesel(table_name = crate::schema::process_metrics)]
pub struct ProcessMetricRow {
    pub timestamp: DateTime<Utc>,
    pub poller_id: Option<String>,
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
            "poller_id": self.poller_id,
            "agent_id": self.agent_id,
            "host_id": self.host_id,
            "pid": self.pid,
            "name": self.name,
            "cpu_usage": self.cpu_usage,
            "memory_usage": self.memory_usage,
            "status": self.status,
            "start_time": self.start_time,
            "device_id": self.device_id,
            "partition": self.partition,
        })
    }
}

#[derive(Debug, Clone, QueryableByName)]
pub struct TraceSummaryRow {
    #[diesel(sql_type = Timestamptz)]
    pub timestamp: DateTime<Utc>,
    #[diesel(sql_type = Text)]
    pub trace_id: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub root_span_id: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub root_span_name: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub root_service_name: Option<String>,
    #[diesel(sql_type = Nullable<Int4>)]
    pub root_span_kind: Option<i32>,
    #[diesel(sql_type = Nullable<Int8>)]
    pub start_time_unix_nano: Option<i64>,
    #[diesel(sql_type = Nullable<Int8>)]
    pub end_time_unix_nano: Option<i64>,
    #[diesel(sql_type = Nullable<Float8>)]
    pub duration_ms: Option<f64>,
    #[diesel(sql_type = Nullable<Int4>)]
    pub status_code: Option<i32>,
    #[diesel(sql_type = Nullable<Text>)]
    pub status_message: Option<String>,
    #[diesel(sql_type = Nullable<Array<Text>>)]
    pub service_set: Option<Vec<String>>,
    #[diesel(sql_type = Nullable<Int8>)]
    pub span_count: Option<i64>,
    #[diesel(sql_type = Nullable<Int8>)]
    pub error_count: Option<i64>,
}

impl TraceSummaryRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "trace_id": self.trace_id,
            "root_span_id": self.root_span_id,
            "root_span_name": self.root_span_name,
            "root_service_name": self.root_service_name,
            "root_span_kind": self.root_span_kind,
            "start_time_unix_nano": self.start_time_unix_nano,
            "end_time_unix_nano": self.end_time_unix_nano,
            "duration_ms": self.duration_ms,
            "status_code": self.status_code,
            "status_message": self.status_message,
            "service_set": self.service_set.unwrap_or_default(),
            "span_count": self.span_count.unwrap_or(0),
            "error_count": self.error_count.unwrap_or(0),
        })
    }
}
