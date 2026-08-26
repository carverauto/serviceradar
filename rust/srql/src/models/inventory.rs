//! Fleet inventory rows: agents, add-on statuses, devices, gateways, and
//! service status.

use crate::jsonb::DbJson;
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::prelude::*;
use diesel::sql_types::{Bool, Int4, Jsonb, Nullable, Text, Timestamptz, Uuid as SqlUuid};
use serde::Serialize;
use uuid::Uuid;

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
    pub tags: Option<DbJson>,
    pub metadata: Option<DbJson>,
    pub deleted_at: Option<DateTime<Utc>>,
    pub deleted_by: Option<String>,
    pub deleted_reason: Option<String>,
    pub partition: String,
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
            "tags": self
                .tags
                .map_or(serde_json::json!({}), serde_json::Value::from),
            "metadata": self
                .metadata
                .map_or(serde_json::json!({}), serde_json::Value::from),
            "deleted_at": self.deleted_at,
            "deleted_by": self.deleted_by,
            "deleted_reason": self.deleted_reason,
            "partition": self.partition,
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
