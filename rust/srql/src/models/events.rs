//! Event-shaped rows: OCSF events, BMP routing events, and alerts.

use super::common::source_device_uid_from_json_values;
use crate::jsonb::DbJson;
use chrono::{DateTime, Utc};
use diesel::prelude::*;
use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

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
            &self.metadata,
            &self.device,
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
        let finding_uid = first_non_blank([
            json_path_string(&self.metadata, &["finding_info", "uid"]),
            json_path_string(&self.metadata, &["security_signal", "finding_uid"]),
            json_path_string(&self.metadata, &["event_id"]),
            json_path_string(&self.metadata, &["uid"]),
        ]);
        let finding_title = first_non_blank([
            json_path_string(&self.metadata, &["finding_info", "title"]),
            json_path_string(&self.metadata, &["title"]),
            message.clone(),
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
            "finding_uid": finding_uid,
            "finding_title": finding_title,
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
        if let Some(value) = obj.get(key).and_then(|v| v.as_str())
            && !value.is_empty()
        {
            return Some(value.to_string());
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
    if let Some(message) = json_path_string(raw, &["message"])
        && !message.trim().is_empty()
    {
        return Some(message);
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

#[cfg(test)]
mod tests {
    use super::*;

    fn event_row(metadata: Value, message: Option<String>) -> EventRow {
        EventRow {
            time: DateTime::parse_from_rfc3339("2026-06-13T12:00:00Z")
                .unwrap()
                .with_timezone(&Utc),
            id: Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap(),
            class_uid: 2002,
            category_uid: 2,
            type_uid: 200201,
            activity_id: 1,
            activity_name: Some("Create".to_owned()),
            severity_id: Some(4),
            severity: Some("High".to_owned()),
            message,
            status_id: Some(2),
            status: Some("Failure".to_owned()),
            status_code: None,
            status_detail: None,
            metadata: DbJson(metadata),
            observables: DbJson(serde_json::json!([])),
            trace_id: None,
            span_id: None,
            actor: DbJson(serde_json::json!({})),
            device: DbJson(serde_json::json!({})),
            src_endpoint: DbJson(serde_json::json!({})),
            dst_endpoint: DbJson(serde_json::json!({})),
            log_name: Some("trivy.report.vulnerability".to_owned()),
            log_provider: Some("trivy".to_owned()),
            log_level: Some("HIGH".to_owned()),
            log_version: Some("1.0".to_owned()),
            unmapped: DbJson(serde_json::json!({})),
            raw_data: None,
            created_at: DateTime::parse_from_rfc3339("2026-06-13T12:00:01Z")
                .unwrap()
                .with_timezone(&Utc),
        }
    }

    #[test]
    fn event_row_projects_legacy_finding_identity_metadata() {
        let json = event_row(
            serde_json::json!({
                "event_id": "legacy-trivy-event",
                "uid": "legacy-trivy-report"
            }),
            Some("Trivy HIGH finding on Pod/demo/nginx".to_owned()),
        )
        .into_json();

        assert_eq!(json["finding_uid"], "legacy-trivy-event");
        assert_eq!(
            json["finding_title"],
            "Trivy HIGH finding on Pod/demo/nginx"
        );
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
