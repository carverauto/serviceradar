use crate::jsonb::DbJson;
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::sql_types::{Array, BigInt, Bool, Float8, Int4, Jsonb, Nullable, Text, Timestamptz};

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(super) struct InterfaceRow {
    #[diesel(sql_type = Timestamptz)]
    timestamp: DateTime<Utc>,
    #[diesel(sql_type = Nullable<Text>)]
    agent_id: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    gateway_id: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    device_ip: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    device_id: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    interface_uid: Option<String>,
    #[diesel(sql_type = Nullable<Int4>)]
    if_index: Option<i32>,
    #[diesel(sql_type = Nullable<Text>)]
    if_name: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    if_descr: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    if_alias: Option<String>,
    #[diesel(sql_type = Nullable<Int4>)]
    if_type: Option<i32>,
    #[diesel(sql_type = Nullable<Text>)]
    if_type_name: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    interface_kind: Option<String>,
    #[diesel(sql_type = Nullable<BigInt>)]
    if_speed: Option<i64>,
    #[diesel(sql_type = Nullable<BigInt>)]
    speed_bps: Option<i64>,
    #[diesel(sql_type = Nullable<Int4>)]
    mtu: Option<i32>,
    #[diesel(sql_type = Nullable<Text>)]
    duplex: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    if_phys_address: Option<String>,
    #[diesel(sql_type = Nullable<Array<Text>>)]
    ip_addresses: Option<Vec<String>>,
    #[diesel(sql_type = Nullable<Int4>)]
    if_admin_status: Option<i32>,
    #[diesel(sql_type = Nullable<Int4>)]
    if_oper_status: Option<i32>,
    #[diesel(sql_type = Nullable<Jsonb>)]
    metadata: Option<DbJson>,
    #[diesel(sql_type = Nullable<Jsonb>)]
    available_metrics: Option<DbJson>,
    #[diesel(sql_type = Nullable<Float8>)]
    in_errors: Option<f64>,
    #[diesel(sql_type = Nullable<Float8>)]
    out_errors: Option<f64>,
    #[diesel(sql_type = Timestamptz)]
    created_at: DateTime<Utc>,
    // Fields from interface_settings table (LEFT JOIN)
    #[diesel(sql_type = Bool)]
    favorited: bool,
    #[diesel(sql_type = Bool)]
    metrics_enabled: bool,
}

impl InterfaceRow {
    pub(super) fn into_json(self) -> serde_json::Value {
        let speed_bps = self.speed_bps.or(self.if_speed);
        serde_json::json!({
            "timestamp": self.timestamp,
            "agent_id": self.agent_id,
            "gateway_id": self.gateway_id,
            "device_ip": self.device_ip,
            "device_id": self.device_id,
            "uid": self.device_id,
            "interface_uid": self.interface_uid,
            "if_index": self.if_index,
            "if_name": self.if_name,
            "if_descr": self.if_descr,
            "if_alias": self.if_alias,
            "if_type": self.if_type,
            "if_type_name": self.if_type_name,
            "interface_kind": self.interface_kind,
            "if_speed": self.if_speed,
            "speed_bps": speed_bps,
            "mtu": self.mtu,
            "duplex": self.duplex,
            "if_phys_address": self.if_phys_address,
            "mac": self.if_phys_address,
            "ip_addresses": self.ip_addresses.unwrap_or_default(),
            "if_admin_status": self.if_admin_status,
            "if_oper_status": self.if_oper_status,
            "metadata": self
                .metadata
                .map_or(serde_json::json!({}), serde_json::Value::from),
            "available_metrics": self.available_metrics,
            "in_errors": self.in_errors,
            "out_errors": self.out_errors,
            "created_at": self.created_at,
            // Interface settings (from LEFT JOIN with interface_settings table)
            "favorited": self.favorited,
            "metrics_enabled": self.metrics_enabled,
        })
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(super) struct StatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    pub(super) payload: Option<DbJson>,
}
