//! Data models for CNPG-backed SRQL queries.

use crate::jsonb::DbJson;
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::prelude::*;
use diesel::sql_types::{
    Array, Bool, Float8, Int4, Int8, Jsonb, Nullable, Text, Timestamptz, Uuid as SqlUuid,
};
use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

const DEVICE_IDENTITY_KEYS: &[&str] = &[
    "serviceradar.device_id",
    "serviceradar.device.uid",
    "device_id",
    "device_uid",
    "source_device_uid",
    "target_device_uid",
    "uid",
    "id",
];

/// OCSF-aligned agent row (OCSF v1.7.0 Agent object)
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::ocsf_agents, check_for_backend(diesel::pg::Pg))]
pub struct AgentRow {
    pub uid: String,
    pub name: Option<String>,
    pub type_id: i32,
    pub agent_type: Option<String>,
    pub version: Option<String>,
    pub vendor_name: Option<String>,
    pub uid_alt: Option<String>,
    pub policies: Option<DbJson>,
    pub gateway_id: Option<String>,
    pub capabilities: Option<Vec<String>>,
    pub host: Option<String>,
    pub ip: Option<String>,
    pub first_seen_time: Option<DateTime<Utc>>,
    pub last_seen_time: Option<DateTime<Utc>>,
    pub created_time: DateTime<Utc>,
    pub modified_time: DateTime<Utc>,
    pub metadata: Option<DbJson>,
    pub config_source: Option<String>,
    pub desired_version: Option<String>,
    pub release_rollout_state: Option<String>,
    pub last_update_at: Option<DateTime<Utc>>,
    pub last_update_error: Option<String>,
}

impl AgentRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "uid": self.uid,
            "name": self.name,
            "type_id": self.type_id,
            "type": self.agent_type,
            "version": self.version,
            "vendor_name": self.vendor_name,
            "uid_alt": self.uid_alt,
            "policies": self.policies,
            "gateway_id": self.gateway_id,
            "capabilities": self.capabilities.unwrap_or_default(),
            "host": self.host,
            "ip": self.ip,
            "first_seen_time": self.first_seen_time,
            "last_seen_time": self.last_seen_time,
            "first_seen": self.first_seen_time,  // Alias for consistency
            "last_seen": self.last_seen_time,    // Alias for consistency
            "created_time": self.created_time,
            "modified_time": self.modified_time,
            "metadata": self
                .metadata
                .map_or(serde_json::json!({}), serde_json::Value::from),
            "config_source": self.config_source,
            "desired_version": self.desired_version,
            "release_rollout_state": self.release_rollout_state,
            "last_update_at": self.last_update_at,
            "last_update_error": self.last_update_error,
        })
    }
}

/// Per-agent observed native add-on status (issue 3425, task 7.2).
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::addon_statuses, check_for_backend(diesel::pg::Pg))]
pub struct AddonStatusRow {
    pub id: Uuid,
    pub agent_uid: String,
    pub addon_id: String,
    pub state: String,
    pub active: bool,
    pub degradation_reason: Option<String>,
    pub pid: Option<i32>,
    pub restart_count: i32,
    pub last_health_at: Option<DateTime<Utc>>,
    pub version: Option<String>,
    pub arch: Option<String>,
    pub reported_at: DateTime<Utc>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl AddonStatusRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "id": self.id.to_string(),
            "agent_uid": self.agent_uid,
            "addon_id": self.addon_id,
            "state": self.state,
            "active": self.active,
            "degradation_reason": self.degradation_reason,
            "pid": self.pid,
            "restart_count": self.restart_count,
            "last_health_at": self.last_health_at,
            "version": self.version,
            "arch": self.arch,
            "reported_at": self.reported_at,
            "inserted_at": self.inserted_at,
            "updated_at": self.updated_at,
        })
    }
}

/// Endpoint package inventory row collected by the native endpoint inventory add-on.
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(
    table_name = crate::schema::endpoint_inventory_packages,
    check_for_backend(diesel::pg::Pg)
)]
pub struct EndpointPackageRow {
    pub id: Uuid,
    pub scan_ref: Uuid,
    pub device_uid: Option<String>,
    pub agent_id: String,
    pub name: String,
    pub version: Option<String>,
    pub architecture: Option<String>,
    pub package_manager: String,
    pub ecosystem: Option<String>,
    pub purl: Option<String>,
    pub purl_canonical: String,
    pub endpoint_package_ref: Uuid,
    pub cpes: Vec<String>,
    pub supplier: Option<String>,
    pub license: Option<String>,
    pub source: Option<String>,
    pub evidence: DbJson,
    pub current: bool,
    pub metadata: DbJson,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl EndpointPackageRow {
    pub fn into_json(self) -> serde_json::Value {
        let device_uid = self.device_uid;
        let device_id = device_uid.clone();
        let manager = self.package_manager.clone();
        let canonical_purl = self.purl_canonical.clone();

        serde_json::json!({
            "id": self.id.to_string(),
            "scan_ref": self.scan_ref.to_string(),
            "device_uid": device_uid,
            "device_id": device_id,
            "agent_id": self.agent_id,
            "name": self.name,
            "version": self.version,
            "architecture": self.architecture,
            "package_manager": self.package_manager,
            "manager": manager,
            "ecosystem": self.ecosystem,
            "purl": self.purl,
            "purl_canonical": self.purl_canonical,
            "canonical_purl": canonical_purl,
            "endpoint_package_ref": self.endpoint_package_ref.to_string(),
            "package_id": self.endpoint_package_ref.to_string(),
            "has_package": {
                "device_uid": device_id,
                "package_id": self.endpoint_package_ref.to_string(),
                "relation": "HAS_PACKAGE",
            },
            "cpes": self.cpes,
            "supplier": self.supplier,
            "license": self.license,
            "source": self.source,
            "evidence": serde_json::Value::from(self.evidence),
            "current": self.current,
            "metadata": serde_json::Value::from(self.metadata),
            "inserted_at": self.inserted_at,
            "updated_at": self.updated_at,
        })
    }
}

/// Normalized endpoint-side package coordinate catalog row.
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(
    table_name = crate::schema::endpoint_packages,
    check_for_backend(diesel::pg::Pg)
)]
pub struct EndpointPackageCatalogRow {
    pub id: Uuid,
    pub coordinate_key: String,
    pub purl_canonical: Option<String>,
    pub primary_cpe: Option<String>,
    pub cpes: Vec<String>,
    pub package_manager: String,
    pub name: String,
    pub version: Option<String>,
    pub architecture: Option<String>,
    pub ecosystem: Option<String>,
    pub source_scope: String,
    pub metadata: DbJson,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl EndpointPackageCatalogRow {
    pub fn into_json(self) -> serde_json::Value {
        let canonical_purl = self.purl_canonical.clone();

        serde_json::json!({
            "id": self.id.to_string(),
            "package_id": self.id.to_string(),
            "coordinate_key": self.coordinate_key,
            "purl_canonical": self.purl_canonical,
            "canonical_purl": canonical_purl,
            "primary_cpe": self.primary_cpe,
            "cpes": self.cpes,
            "package_manager": self.package_manager,
            "manager": self.package_manager,
            "name": self.name,
            "version": self.version,
            "architecture": self.architecture,
            "ecosystem": self.ecosystem,
            "source_scope": self.source_scope,
            "metadata": serde_json::Value::from(self.metadata),
            "inserted_at": self.inserted_at,
            "updated_at": self.updated_at,
        })
    }
}

/// Endpoint inventory scan metadata and freshness state.
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(
    table_name = crate::schema::endpoint_inventory_scans,
    check_for_backend(diesel::pg::Pg)
)]
pub struct EndpointInventoryScanRow {
    pub id: Uuid,
    pub device_uid: Option<String>,
    pub agent_id: String,
    pub scan_id: String,
    pub collector_name: Option<String>,
    pub collector_version: Option<String>,
    pub state: String,
    pub coverage_state: String,
    pub package_count: i32,
    pub enabled_sources: Vec<String>,
    pub manager_counts: DbJson,
    pub source_summaries: Vec<DbJson>,
    pub artifact_count: i32,
    pub current: bool,
    pub last_successful_scan_at: Option<DateTime<Utc>>,
    pub last_scan_at: Option<DateTime<Utc>>,
    pub last_changed_scan_at: Option<DateTime<Utc>>,
    pub ingested_at: Option<DateTime<Utc>>,
    pub package_set_hash: Option<String>,
    pub artifact_hash: Option<String>,
    pub hash_algorithm: Option<String>,
    pub upload_reason: Option<String>,
    pub server_package_set_hash: Option<String>,
    pub package_set_hash_mismatch: bool,
    pub unchanged_scan_count: i32,
    pub reconcile_floor_due: bool,
    pub metadata: DbJson,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl EndpointInventoryScanRow {
    pub fn into_json(self) -> serde_json::Value {
        let device_uid = self.device_uid;
        let device_id = device_uid.clone();
        let freshness = endpoint_inventory_freshness(self.last_successful_scan_at);
        let freshness_verdict = freshness
            .get("verdict")
            .and_then(|value| value.as_str())
            .unwrap_or("unknown")
            .to_string();

        serde_json::json!({
            "id": self.id.to_string(),
            "device_uid": device_uid,
            "device_id": device_id,
            "agent_id": self.agent_id,
            "scan_id": self.scan_id,
            "collector_name": self.collector_name,
            "collector_version": self.collector_version,
            "state": self.state,
            "coverage_state": self.coverage_state,
            "package_count": self.package_count,
            "enabled_sources": self.enabled_sources,
            "manager_counts": serde_json::Value::from(self.manager_counts),
            "source_summaries": self.source_summaries.into_iter().map(serde_json::Value::from).collect::<Vec<_>>(),
            "artifact_count": self.artifact_count,
            "current": self.current,
            "last_successful_scan_at": self.last_successful_scan_at,
            "last_scan_at": self.last_scan_at,
            "last_changed_scan_at": self.last_changed_scan_at,
            "ingested_at": self.ingested_at,
            "package_set_hash": self.package_set_hash,
            "artifact_hash": self.artifact_hash,
            "hash_algorithm": self.hash_algorithm,
            "upload_reason": self.upload_reason,
            "server_package_set_hash": self.server_package_set_hash,
            "package_set_hash_mismatch": self.package_set_hash_mismatch,
            "unchanged_scan_count": self.unchanged_scan_count,
            "reconcile_floor_due": self.reconcile_floor_due,
            "freshness_verdict": freshness_verdict,
            "freshness": freshness,
            "metadata": serde_json::Value::from(self.metadata),
            "inserted_at": self.inserted_at,
            "updated_at": self.updated_at,
        })
    }
}

const ENDPOINT_INVENTORY_STALE_THRESHOLD_SECONDS: i64 = 86_400;

fn endpoint_inventory_freshness(
    last_successful_scan_at: Option<DateTime<Utc>>,
) -> serde_json::Value {
    let Some(last_successful) = last_successful_scan_at else {
        return serde_json::json!({
            "verdict": "unknown",
            "age_seconds": null,
            "stale_threshold_seconds": ENDPOINT_INVENTORY_STALE_THRESHOLD_SECONDS,
            "last_successful_scan_at": null,
        });
    };

    let age_seconds = (Utc::now() - last_successful).num_seconds().max(0);
    let verdict = if age_seconds > ENDPOINT_INVENTORY_STALE_THRESHOLD_SECONDS {
        "stale"
    } else {
        "fresh"
    };

    serde_json::json!({
        "verdict": verdict,
        "age_seconds": age_seconds,
        "stale_threshold_seconds": ENDPOINT_INVENTORY_STALE_THRESHOLD_SECONDS,
        "last_successful_scan_at": last_successful,
    })
}

/// OCSF-aligned device row (OCSF v1.7.0 Device object)
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::ocsf_devices, check_for_backend(diesel::pg::Pg))]
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
    pub os: Option<DbJson>,
    pub hw_info: Option<DbJson>,
    pub network_interfaces: Option<DbJson>,
    pub owner: Option<DbJson>,
    pub org: Option<DbJson>,
    pub groups: Option<DbJson>,
    pub agent_list: Option<DbJson>,

    // ServiceRadar-specific fields
    pub gateway_id: Option<String>,
    pub agent_id: Option<String>,
    pub availability_source_agent_id: Option<String>,
    pub discovery_sources: Option<Vec<String>>,
    pub is_available: Option<bool>,
    pub is_active: Option<bool>,
    pub metadata: Option<DbJson>,
    pub deleted_at: Option<DateTime<Utc>>,
    pub deleted_by: Option<String>,
    pub deleted_reason: Option<String>,
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
            "gateway_id": self.gateway_id,
            "agent_id": self.agent_id,
            "availability_source_agent_id": self.availability_source_agent_id,
            "discovery_sources": self.discovery_sources.unwrap_or_default(),
            "is_available": self.is_available.unwrap_or(false),
            "is_active": self.is_active.unwrap_or(true),
            "metadata": self
                .metadata
                .map_or(serde_json::json!({}), serde_json::Value::from),
            "deleted_at": self.deleted_at,
            "deleted_by": self.deleted_by,
            "deleted_reason": self.deleted_reason,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::bmp_routing_events, check_for_backend(diesel::pg::Pg))]
pub struct BmpRoutingEventRow {
    pub time: DateTime<Utc>,
    pub id: Uuid,
    pub event_type: String,
    pub severity_id: Option<i32>,
    pub router_id: Option<String>,
    pub router_ip: Option<String>,
    pub peer_ip: Option<String>,
    pub peer_asn: Option<i64>,
    pub local_asn: Option<i64>,
    pub prefix: Option<String>,
    pub message: Option<String>,
    pub metadata: DbJson,
    pub raw_data: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl BmpRoutingEventRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "time": self.time,
            "event_timestamp": self.time,
            "id": self.id.to_string(),
            "event_type": self.event_type,
            "severity_id": self.severity_id,
            "router_id": self.router_id,
            "router_ip": self.router_ip,
            "peer_ip": self.peer_ip,
            "peer_asn": self.peer_asn,
            "local_asn": self.local_asn,
            "prefix": self.prefix,
            "message": self.message,
            "metadata": self.metadata,
            "raw_data": self.raw_data,
            "created_at": self.created_at,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::ocsf_events, check_for_backend(diesel::pg::Pg))]
pub struct EventRow {
    pub time: DateTime<Utc>,
    pub id: Uuid,
    pub class_uid: i32,
    pub category_uid: i32,
    pub type_uid: i32,
    pub activity_id: i32,
    pub activity_name: Option<String>,
    pub severity_id: Option<i32>,
    pub severity: Option<String>,
    pub message: Option<String>,
    pub status_id: Option<i32>,
    pub status: Option<String>,
    pub status_code: Option<String>,
    pub status_detail: Option<String>,
    pub metadata: DbJson,
    pub observables: DbJson,
    pub trace_id: Option<String>,
    pub span_id: Option<String>,
    pub actor: DbJson,
    pub device: DbJson,
    pub src_endpoint: DbJson,
    pub dst_endpoint: DbJson,
    pub log_name: Option<String>,
    pub log_provider: Option<String>,
    pub log_level: Option<String>,
    pub log_version: Option<String>,
    pub unmapped: DbJson,
    pub raw_data: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl EventRow {
    pub fn into_json(self) -> serde_json::Value {
        let id = self.id.to_string();
        let host = extract_device_host(&self.device);
        let raw_json = self
            .raw_data
            .as_deref()
            .and_then(|raw_data| serde_json::from_str::<Value>(raw_data).ok());
        let message = first_non_blank([
            self.message.clone(),
            raw_json.as_ref().and_then(derive_event_message_from_raw),
        ]);
        let source_device_uid = source_device_uid_from_json_values(&[
            &self.device,
            &self.metadata,
            &self.unmapped,
            &self.observables,
        ]);
        let source = first_non_blank([
            self.log_provider.clone(),
            host.clone(),
            raw_json.as_ref().and_then(derive_event_source_from_raw),
            self.log_name.clone(),
            source_device_uid.clone(),
        ]);

        serde_json::json!({
            "time": self.time,
            "event_timestamp": self.time,
            "id": id,
            "class_uid": self.class_uid,
            "category_uid": self.category_uid,
            "type_uid": self.type_uid,
            "activity_id": self.activity_id,
            "activity_name": self.activity_name,
            "severity_id": self.severity_id,
            "severity": self.severity,
            "message": message.clone(),
            "status_id": self.status_id,
            "status": self.status,
            "status_code": self.status_code,
            "status_detail": self.status_detail,
            "metadata": self.metadata,
            "observables": self.observables,
            "trace_id": self.trace_id,
            "span_id": self.span_id,
            "actor": self.actor,
            "device": self.device,
            "src_endpoint": self.src_endpoint,
            "dst_endpoint": self.dst_endpoint,
            "log_name": self.log_name,
            "log_provider": self.log_provider,
            "log_level": self.log_level,
            "log_version": self.log_version,
            "unmapped": self.unmapped,
            "raw_data": self.raw_data,
            "host": host,
            "source_device_uid": source_device_uid,
            "source": source,
            "short_message": message,
            "created_at": self.created_at,
        })
    }
}

fn first_non_blank(values: impl IntoIterator<Item = Option<String>>) -> Option<String> {
    values
        .into_iter()
        .flatten()
        .map(|value| value.trim().to_owned())
        .find(|value| !value.is_empty())
}

fn extract_device_host(device: &serde_json::Value) -> Option<String> {
    let obj = device.as_object()?;
    for key in ["hostname", "name", "host"] {
        if let Some(value) = obj.get(key).and_then(|v| v.as_str()) {
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn derive_event_source_from_raw(raw: &Value) -> Option<String> {
    first_non_blank([
        json_path_string(raw, &["log_provider"]),
        json_path_string(raw, &["device", "name"]),
        json_path_string(raw, &["device", "hostname"]),
        json_path_string(raw, &["unmapped", "device_name"]),
        json_path_string(raw, &["log_name"]),
    ])
}

fn derive_event_message_from_raw(raw: &Value) -> Option<String> {
    if let Some(message) = json_path_string(raw, &["message"]) {
        if !message.trim().is_empty() {
            return Some(message);
        }
    }

    let hostname = json_path_string(raw, &["query", "hostname"])?;
    let policy = json_path_string(raw, &["firewall_rule", "name"]);
    let policy_kind = json_path_string(raw, &["firewall_rule", "type"]);

    if let Some(policy) = policy.filter(|value| !value.trim().is_empty()) {
        let kind = policy_kind.unwrap_or_else(|| "policy".to_owned());
        return Some(format!(
            "PowerDNS RPZ {kind} match for {hostname} via {policy}"
        ));
    }

    let activity =
        json_path_string(raw, &["activity_name"]).unwrap_or_else(|| "DNS event".to_owned());
    Some(format!("PowerDNS {activity} for {hostname}"))
}

fn json_path_string(value: &Value, path: &[&str]) -> Option<String> {
    let mut current = value;
    for key in path {
        current = current.get(*key)?;
    }
    match current {
        Value::String(value) if !value.trim().is_empty() => Some(value.clone()),
        Value::Number(value) => Some(value.to_string()),
        _ => None,
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::device_updates, check_for_backend(diesel::pg::Pg))]
pub struct DeviceUpdateRow {
    pub observed_at: DateTime<Utc>,
    pub agent_id: String,
    pub gateway_id: String,
    pub partition: String,
    pub device_id: String,
    pub discovery_source: String,
    pub ip: Option<String>,
    pub mac: Option<String>,
    pub hostname: Option<String>,
    pub available: Option<bool>,
    pub metadata: Option<DbJson>,
    pub created_at: DateTime<Utc>,
}

impl DeviceUpdateRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "observed_at": self.observed_at,
            "agent_id": self.agent_id,
            "gateway_id": self.gateway_id,
            "partition": self.partition,
            "uid": self.device_id,
            "discovery_source": self.discovery_source,
            "ip": self.ip,
            "mac": self.mac,
            "hostname": self.hostname,
            "available": self.available,
            "metadata": self
                .metadata
                .map_or(serde_json::json!({}), serde_json::Value::from),
            "created_at": self.created_at,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::logs, check_for_backend(diesel::pg::Pg))]
pub struct LogRow {
    pub timestamp: DateTime<Utc>,
    pub observed_timestamp: Option<DateTime<Utc>>,
    pub id: Uuid,
    pub trace_id: Option<String>,
    pub span_id: Option<String>,
    pub trace_flags: Option<i32>,
    pub severity_text: Option<String>,
    pub severity_number: Option<i32>,
    pub body: Option<String>,
    pub event_name: Option<String>,
    pub source: Option<String>,
    pub service_name: Option<String>,
    pub service_version: Option<String>,
    pub service_instance: Option<String>,
    pub scope_name: Option<String>,
    pub scope_version: Option<String>,
    pub scope_attributes: Option<String>,
    pub attributes: Option<String>,
    pub resource_attributes: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl LogRow {
    pub fn into_json(self) -> serde_json::Value {
        let source_device_uid = source_device_uid_from_attributes(
            self.resource_attributes.as_deref(),
            self.attributes.as_deref(),
        );

        serde_json::json!({
            "id": self.id.to_string(),
            "timestamp": self.timestamp,
            "observed_timestamp": self.observed_timestamp,
            "trace_id": self.trace_id,
            "span_id": self.span_id,
            "trace_flags": self.trace_flags,
            "severity_text": self.severity_text,
            "severity_number": self.severity_number,
            "body": self.body,
            "event_name": self.event_name,
            "source": self.source,
            "service_name": self.service_name,
            "service_version": self.service_version,
            "service_instance": self.service_instance,
            "scope_name": self.scope_name,
            "scope_version": self.scope_version,
            "scope_attributes": self.scope_attributes,
            "attributes": self.attributes.clone(),
            "resource_attributes": self.resource_attributes,
            "source_device_uid": source_device_uid,
            "raw_data": self.attributes.unwrap_or_default(),
        })
    }
}

fn source_device_uid_from_attributes(
    resource_attributes: Option<&str>,
    attributes: Option<&str>,
) -> Option<String> {
    resource_attributes
        .and_then(|raw| string_field_from_json(raw, DEVICE_IDENTITY_KEYS))
        .or_else(|| attributes.and_then(|raw| string_field_from_json(raw, DEVICE_IDENTITY_KEYS)))
}

fn source_device_uid_from_json_values(values: &[&Value]) -> Option<String> {
    values
        .iter()
        .find_map(|value| {
            DEVICE_IDENTITY_KEYS
                .iter()
                .find_map(|key| extract_json_string(value, key))
        })
        .filter(|value| !value.trim().is_empty())
}

fn string_field_from_json(raw: &str, keys: &[&str]) -> Option<String> {
    let value: Value = serde_json::from_str(raw).ok()?;

    keys.iter()
        .find_map(|key| extract_json_string(&value, key))
        .filter(|value| !value.trim().is_empty())
}

fn extract_json_string(value: &Value, key: &str) -> Option<String> {
    if let Value::Object(map) = value {
        if let Some(Value::String(raw)) = map.get(key) {
            return Some(raw.clone());
        }

        let mut current = value;
        for part in key.split('.') {
            current = current.get(part)?;
        }

        match current {
            Value::String(raw) => Some(raw.clone()),
            Value::Number(number) => Some(number.to_string()),
            _ => None,
        }
    } else {
        None
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::otel_traces, check_for_backend(diesel::pg::Pg))]
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

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::service_status, check_for_backend(diesel::pg::Pg))]
pub struct ServiceStatusRow {
    pub timestamp: DateTime<Utc>,
    pub gateway_id: String,
    pub agent_id: Option<String>,
    pub service_id: Option<Uuid>,
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
        let service_id = self.service_id.map(|id| id.to_string());
        let uid = service_id.clone();

        serde_json::json!({
            "timestamp": self.timestamp,
            "last_seen": self.timestamp,
            "created_at": self.created_at,
            "gateway_id": self.gateway_id,
            "agent_id": self.agent_id,
            "service_id": service_id,
            "uid": uid,
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

#[derive(Debug, Clone, QueryableByName, Serialize)]
#[diesel(table_name = crate::schema::gateways, check_for_backend(diesel::pg::Pg))]
pub struct GatewayRow {
    #[diesel(sql_type = Text)]
    pub gateway_id: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub component_id: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub registration_source: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub status: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub spiffe_identity: Option<String>,
    #[diesel(sql_type = Nullable<Timestamptz>)]
    pub first_registered: Option<DateTime<Utc>>,
    #[diesel(sql_type = Nullable<Timestamptz>)]
    pub first_seen: Option<DateTime<Utc>>,
    #[diesel(sql_type = Nullable<Timestamptz>)]
    pub last_seen: Option<DateTime<Utc>>,
    #[diesel(sql_type = Nullable<Jsonb>)]
    pub metadata: Option<DbJson>,
    #[diesel(sql_type = Nullable<Text>)]
    pub created_by: Option<String>,
    #[diesel(sql_type = Nullable<Bool>)]
    pub is_healthy: Option<bool>,
    #[diesel(sql_type = Nullable<Int4>)]
    pub agent_count: Option<i32>,
    #[diesel(sql_type = Nullable<Int4>)]
    pub checker_count: Option<i32>,
    #[diesel(sql_type = Nullable<Timestamptz>)]
    pub updated_at: Option<DateTime<Utc>>,
    #[diesel(sql_type = Nullable<SqlUuid>)]
    pub partition_id: Option<Uuid>,
}

impl GatewayRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "gateway_id": self.gateway_id,
            "component_id": self.component_id,
            "registration_source": self.registration_source,
            "status": self.status,
            "spiffe_identity": self.spiffe_identity,
            "first_registered": self.first_registered,
            "first_seen": self.first_seen,
            "last_seen": self.last_seen,
            "metadata": self
                .metadata
                .map_or(serde_json::json!({}), serde_json::Value::from),
            "created_by": self.created_by,
            "is_healthy": self.is_healthy,
            "agent_count": self.agent_count.unwrap_or(0),
            "checker_count": self.checker_count.unwrap_or(0),
            "updated_at": self.updated_at,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::otel_metrics, check_for_backend(diesel::pg::Pg))]
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

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::timeseries_metrics, check_for_backend(diesel::pg::Pg))]
pub struct TimeseriesMetricRow {
    pub timestamp: DateTime<Utc>,
    pub gateway_id: String,
    pub agent_id: Option<String>,
    pub series_key: String,
    pub metric_name: String,
    pub metric_type: String,
    pub device_id: Option<String>,
    pub value: f64,
    pub unit: Option<String>,
    pub tags: Option<DbJson>,
    pub partition: Option<String>,
    pub scale: Option<f64>,
    pub is_delta: Option<bool>,
    pub target_device_ip: Option<String>,
    pub if_index: Option<i32>,
    pub metadata: Option<DbJson>,
    pub created_at: DateTime<Utc>,
}

impl TimeseriesMetricRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "gateway_id": self.gateway_id,
            "agent_id": self.agent_id,
            "series_key": self.series_key,
            "metric_name": self.metric_name,
            "metric_type": self.metric_type,
            "uid": self.device_id,
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

#[derive(Debug, Clone, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
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

/// Alert row for monitoring alerts
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::alerts, check_for_backend(diesel::pg::Pg))]
pub struct AlertRow {
    pub id: Uuid,
    pub title: String,
    pub description: Option<String>,
    pub severity: String,
    pub status: String,
    pub source_type: Option<String>,
    pub source_id: Option<String>,
    pub service_check_id: Option<Uuid>,
    pub device_uid: Option<String>,
    pub agent_uid: Option<String>,
    pub event_id: Option<Uuid>,
    pub event_time: Option<DateTime<Utc>>,
    pub metric_name: Option<String>,
    pub metric_value: Option<f64>,
    pub threshold_value: Option<f64>,
    pub comparison: Option<String>,
    pub triggered_at: Option<DateTime<Utc>>,
    pub acknowledged_at: Option<DateTime<Utc>>,
    pub acknowledged_by: Option<String>,
    pub resolved_at: Option<DateTime<Utc>>,
    pub resolved_by: Option<String>,
    pub resolution_note: Option<String>,
    pub escalated_at: Option<DateTime<Utc>>,
    pub escalation_level: Option<i64>,
    pub escalation_reason: Option<String>,
    pub notification_count: Option<i64>,
    pub last_notification_at: Option<DateTime<Utc>>,
    pub suppressed_until: Option<DateTime<Utc>>,
    pub metadata: Option<DbJson>,
    pub tags: Option<Vec<String>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl AlertRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "id": self.id.to_string(),
            "title": self.title,
            "description": self.description,
            "severity": self.severity,
            "status": self.status,
            "source_type": self.source_type,
            "source_id": self.source_id,
            "service_check_id": self.service_check_id.map(|u| u.to_string()),
            "device_uid": self.device_uid,
            "agent_uid": self.agent_uid,
            "event_id": self.event_id.map(|u| u.to_string()),
            "event_time": self.event_time,
            "metric_name": self.metric_name,
            "metric_value": self.metric_value,
            "threshold_value": self.threshold_value,
            "comparison": self.comparison,
            "triggered_at": self.triggered_at,
            "timestamp": self.triggered_at,  // Alias for sorting/display
            "acknowledged_at": self.acknowledged_at,
            "acknowledged_by": self.acknowledged_by,
            "resolved_at": self.resolved_at,
            "resolved_by": self.resolved_by,
            "resolution_note": self.resolution_note,
            "escalated_at": self.escalated_at,
            "escalation_level": self.escalation_level.unwrap_or(0),
            "escalation_reason": self.escalation_reason,
            "notification_count": self.notification_count.unwrap_or(0),
            "last_notification_at": self.last_notification_at,
            "suppressed_until": self.suppressed_until,
            "metadata": self
                .metadata
                .map_or(serde_json::json!({}), serde_json::Value::from),
            "tags": self.tags.unwrap_or_default(),
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        })
    }
}
