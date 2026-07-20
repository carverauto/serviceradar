use super::*;
use crate::jsonb::DbJson;
use serde::{Deserialize, Serialize};

/// Full flow row including prefix-tag columns (post migration 20260718010000).
#[derive(Queryable, Selectable, Serialize, Deserialize)]
#[diesel(table_name = crate::schema::ocsf_network_activity, check_for_backend(diesel::pg::Pg))]
pub(super) struct FlowRow {
    time: chrono::NaiveDateTime,
    class_uid: i32,
    category_uid: i32,
    activity_id: i32,
    type_uid: i32,
    severity_id: i32,
    start_time: Option<chrono::NaiveDateTime>,
    end_time: Option<chrono::NaiveDateTime>,
    src_endpoint_ip: Option<String>,
    src_endpoint_port: Option<i32>,
    src_as_number: Option<i32>,
    dst_endpoint_ip: Option<String>,
    dst_endpoint_port: Option<i32>,
    dst_as_number: Option<i32>,
    protocol_num: Option<i32>,
    protocol_name: Option<String>,
    protocol_source: Option<String>,
    tcp_flags: Option<i32>,
    tcp_flags_labels: Option<Vec<String>>,
    tcp_flags_source: Option<String>,
    dst_service_label: Option<String>,
    dst_service_source: Option<String>,
    bytes_total: i64,
    packets_total: i64,
    bytes_in: Option<i64>,
    bytes_out: Option<i64>,
    packets_in: Option<i64>,
    packets_out: Option<i64>,
    sampling_rate: i64,
    direction_label: Option<String>,
    direction_source: Option<String>,
    src_hosting_provider: Option<String>,
    src_hosting_provider_source: Option<String>,
    dst_hosting_provider: Option<String>,
    dst_hosting_provider_source: Option<String>,
    src_mac: Option<String>,
    dst_mac: Option<String>,
    src_mac_vendor: Option<String>,
    src_mac_vendor_source: Option<String>,
    dst_mac_vendor: Option<String>,
    dst_mac_vendor_source: Option<String>,
    src_prefix_tags: Option<DbJson>,
    dst_prefix_tags: Option<DbJson>,
    src_prefix_tags_source: Option<String>,
    dst_prefix_tags_source: Option<String>,
    sampler_address: Option<String>,
    ocsf_payload: DbJson,
    partition: Option<String>,
    created_at: chrono::NaiveDateTime,
}

/// Pre-migration flow projection without prefix-tag columns.
///
/// Used when the database has not yet applied migration 20260718010000 so a
/// rolled SRQL binary does not fail every `in:flows` query with undefined_column.
#[derive(Queryable, Selectable, Serialize, Deserialize)]
#[diesel(table_name = crate::schema::ocsf_network_activity, check_for_backend(diesel::pg::Pg))]
pub(super) struct FlowRowLegacy {
    time: chrono::NaiveDateTime,
    class_uid: i32,
    category_uid: i32,
    activity_id: i32,
    type_uid: i32,
    severity_id: i32,
    start_time: Option<chrono::NaiveDateTime>,
    end_time: Option<chrono::NaiveDateTime>,
    src_endpoint_ip: Option<String>,
    src_endpoint_port: Option<i32>,
    src_as_number: Option<i32>,
    dst_endpoint_ip: Option<String>,
    dst_endpoint_port: Option<i32>,
    dst_as_number: Option<i32>,
    protocol_num: Option<i32>,
    protocol_name: Option<String>,
    protocol_source: Option<String>,
    tcp_flags: Option<i32>,
    tcp_flags_labels: Option<Vec<String>>,
    tcp_flags_source: Option<String>,
    dst_service_label: Option<String>,
    dst_service_source: Option<String>,
    bytes_total: i64,
    packets_total: i64,
    bytes_in: Option<i64>,
    bytes_out: Option<i64>,
    packets_in: Option<i64>,
    packets_out: Option<i64>,
    sampling_rate: i64,
    direction_label: Option<String>,
    direction_source: Option<String>,
    src_hosting_provider: Option<String>,
    src_hosting_provider_source: Option<String>,
    dst_hosting_provider: Option<String>,
    dst_hosting_provider_source: Option<String>,
    src_mac: Option<String>,
    dst_mac: Option<String>,
    src_mac_vendor: Option<String>,
    src_mac_vendor_source: Option<String>,
    dst_mac_vendor: Option<String>,
    dst_mac_vendor_source: Option<String>,
    sampler_address: Option<String>,
    ocsf_payload: DbJson,
    partition: Option<String>,
    created_at: chrono::NaiveDateTime,
}

impl FlowRow {
    pub(super) fn into_json(self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

impl FlowRowLegacy {
    pub(super) fn into_json(self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}
