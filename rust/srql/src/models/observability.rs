//! Log, trace-span, and trace-summary rows.

use super::common::source_device_uid_from_attributes;
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::prelude::*;
use diesel::sql_types::{Array, Float8, Int4, Int8, Nullable, Text, Timestamptz};
use serde::Serialize;
use uuid::Uuid;

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

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::otel_traces, check_for_backend(diesel::pg::Pg))]
pub struct TraceSpanRow {
    pub timestamp: DateTime<Utc>,
    pub trace_id: Option<String>,
    pub span_id: String,
    pub parent_span_id: Option<String>,
    pub trace_state: Option<String>,
    pub name: Option<String>,
    pub kind: Option<i32>,
    pub start_time_unix_nano: Option<i64>,
    pub end_time_unix_nano: Option<i64>,
    pub service_name: Option<String>,
    pub service_version: Option<String>,
    pub service_instance: Option<String>,
    pub service_namespace: String,
    pub deployment_environment: String,
    pub scope_name: Option<String>,
    pub scope_version: Option<String>,
    pub scope_attributes: Option<String>,
    pub status_code: Option<i32>,
    pub status_message: Option<String>,
    pub attributes: Option<String>,
    pub resource_attributes: Option<String>,
    pub events: Option<String>,
    pub links: Option<String>,
    pub dropped_attributes_count: i32,
    pub dropped_events_count: i32,
    pub dropped_links_count: i32,
    pub created_at: DateTime<Utc>,
}

impl TraceSpanRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "trace_id": self.trace_id,
            "span_id": self.span_id,
            "parent_span_id": self.parent_span_id,
            "trace_state": self.trace_state,
            "name": self.name,
            "kind": self.kind,
            "start_time_unix_nano": self.start_time_unix_nano,
            "end_time_unix_nano": self.end_time_unix_nano,
            "service_name": self.service_name,
            "service_version": self.service_version,
            "service_instance": self.service_instance,
            "service_namespace": self.service_namespace,
            "deployment_environment": self.deployment_environment,
            "scope_name": self.scope_name,
            "scope_version": self.scope_version,
            "scope_attributes": self.scope_attributes,
            "status_code": self.status_code,
            "status_message": self.status_message,
            "attributes": self.attributes.clone(),
            "resource_attributes": self.resource_attributes,
            "events": self.events,
            "links": self.links,
            "dropped_attributes_count": self.dropped_attributes_count,
            "dropped_events_count": self.dropped_events_count,
            "dropped_links_count": self.dropped_links_count,
            "raw_data": self.attributes.unwrap_or_default(),
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
    #[diesel(sql_type = Text)]
    pub root_service_namespace: String,
    #[diesel(sql_type = Text)]
    pub deployment_environment: String,
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
            "root_service_namespace": self.root_service_namespace,
            "deployment_environment": self.deployment_environment,
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
