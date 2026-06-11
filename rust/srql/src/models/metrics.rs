//! OTEL metric rows (span-derived metrics and metric points) plus generic
//! timeseries metrics.

use crate::jsonb::DbJson;
use chrono::{DateTime, Utc};
use diesel::prelude::*;
use serde::Serialize;

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
    pub ingest_identity: String,
    pub ingest_agent_id: String,
    pub ingest_partition: String,
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
            "ingest_identity": self.ingest_identity,
            "ingest_agent_id": self.ingest_agent_id,
            "ingest_partition": self.ingest_partition,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::otel_metric_points, check_for_backend(diesel::pg::Pg))]
pub struct OtelMetricPointRow {
    pub timestamp: DateTime<Utc>,
    pub metric_name: String,
    pub metric_type: Option<String>,
    pub unit: Option<String>,
    pub temporality: Option<String>,
    pub is_monotonic: Option<bool>,
    pub service_name: String,
    pub attributes: Option<String>,
    pub attributes_hash: String,
    pub value: Option<f64>,
    pub count: Option<i64>,
    pub sum: Option<f64>,
    pub bucket_counts: Option<String>,
    pub explicit_bounds: Option<String>,
    pub start_time_unix_nano: Option<i64>,
    pub scope_name: String,
    pub service_instance_id: String,
    pub created_at: DateTime<Utc>,
    pub ingest_identity: String,
    pub ingest_agent_id: String,
    pub ingest_partition: String,
}

impl OtelMetricPointRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "metric_name": self.metric_name,
            "metric_type": self.metric_type,
            "unit": self.unit,
            "temporality": self.temporality,
            "is_monotonic": self.is_monotonic,
            "service_name": self.service_name,
            "attributes": self.attributes,
            "attributes_hash": self.attributes_hash,
            "value": self.value,
            "count": self.count,
            "sum": self.sum,
            "bucket_counts": self.bucket_counts,
            "explicit_bounds": self.explicit_bounds,
            "start_time_unix_nano": self.start_time_unix_nano,
            "scope_name": self.scope_name,
            "service_instance_id": self.service_instance_id,
            "ingest_identity": self.ingest_identity,
            "ingest_agent_id": self.ingest_agent_id,
            "ingest_partition": self.ingest_partition,
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
