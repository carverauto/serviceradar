//! Horizon telemetry row models: outages, BGP events, BGP zombies, and path hops.

use crate::jsonb::DbJson;
use chrono::{DateTime, Utc};
use diesel::prelude::*;
use serde::Serialize;

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::horizon_outages, check_for_backend(diesel::pg::Pg))]
pub struct HorizonOutageRow {
    pub time: DateTime<Utc>,
    pub outage_id: String,
    pub status: String,
    pub severity: String,
    pub entity_type: String,
    pub entity_key: String,
    pub region: Option<String>,
    pub covering_prefix: Option<String>,
    pub origin_asn: Option<i64>,
    pub corroborating_pop_count: i32,
    pub avg_forwarding_loss_pct: Option<f64>,
    pub avg_synthetic_failure_pct: Option<f64>,
    pub window_start_ms: Option<i64>,
    pub window_end_ms: Option<i64>,
    pub correlated_bgp_event_ids: DbJson,
    pub raw_data: DbJson,
}

impl HorizonOutageRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "time": self.time,
            "outage_id": self.outage_id,
            "status": self.status,
            "severity": self.severity,
            "entity_type": self.entity_type,
            "entity_key": self.entity_key,
            "region": self.region,
            "covering_prefix": self.covering_prefix,
            "origin_asn": self.origin_asn,
            "corroborating_pop_count": self.corroborating_pop_count,
            "avg_forwarding_loss_pct": self.avg_forwarding_loss_pct,
            "avg_synthetic_failure_pct": self.avg_synthetic_failure_pct,
            "window_start_ms": self.window_start_ms,
            "window_end_ms": self.window_end_ms,
            "correlated_bgp_event_ids": self.correlated_bgp_event_ids,
            "raw_data": self.raw_data,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::horizon_bgp_events, check_for_backend(diesel::pg::Pg))]
pub struct HorizonBgpEventRow {
    pub time: DateTime<Utc>,
    pub event_id: String,
    pub kind: String,
    pub level: String,
    pub prefix: String,
    pub origin_asn: Option<i64>,
    pub as_path: DbJson,
    pub rpki_status: Option<String>,
    pub caida_leak_inference: Option<String>,
    pub watchlist_id: Option<String>,
    pub client_label: Option<String>,
    pub raw_data: DbJson,
}

impl HorizonBgpEventRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "time": self.time,
            "event_id": self.event_id,
            "kind": self.kind,
            "level": self.level,
            "prefix": self.prefix,
            "origin_asn": self.origin_asn,
            "as_path": self.as_path,
            "rpki_status": self.rpki_status,
            "caida_leak_inference": self.caida_leak_inference,
            "watchlist_id": self.watchlist_id,
            "client_label": self.client_label,
            "raw_data": self.raw_data,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::horizon_bgp_zombies, check_for_backend(diesel::pg::Pg))]
pub struct HorizonBgpZombieRow {
    pub time: DateTime<Utc>,
    pub episode_id: String,
    pub status: String,
    pub prefix: String,
    pub origin_asn: Option<i64>,
    pub divergence_pct: Option<f64>,
    pub is_beacon: bool,
    pub withdrawn_peers: Option<i32>,
    pub total_peers: Option<i32>,
    pub stuck_peer_asns: DbJson,
    pub first_seen_at: Option<DateTime<Utc>>,
    pub resolved_at: Option<DateTime<Utc>>,
    pub raw_data: DbJson,
}

impl HorizonBgpZombieRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "time": self.time,
            "episode_id": self.episode_id,
            "status": self.status,
            "prefix": self.prefix,
            "origin_asn": self.origin_asn,
            "divergence_pct": self.divergence_pct,
            "is_beacon": self.is_beacon,
            "withdrawn_peers": self.withdrawn_peers,
            "total_peers": self.total_peers,
            "stuck_peer_asns": self.stuck_peer_asns,
            "first_seen_at": self.first_seen_at,
            "resolved_at": self.resolved_at,
            "raw_data": self.raw_data,
        })
    }
}

#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::horizon_path_hops, check_for_backend(diesel::pg::Pg))]
pub struct HorizonPathHopRow {
    pub time: DateTime<Utc>,
    pub round_id: String,
    pub target_id: String,
    pub pop_id: String,
    pub hop_ttl: i32,
    pub hop_ip: Option<String>,
    pub router_alias_id: Option<String>,
    pub alias_confidence: Option<f64>,
    pub asn: Option<i64>,
    pub as_org: Option<String>,
    pub is_cloud: bool,
    pub cloud_provider: Option<String>,
    pub cloud_region: Option<String>,
    pub forwarding_loss_pct: Option<f64>,
    pub avg_rtt_ms: Option<f64>,
    pub effective_path_mtu: Option<i32>,
    pub mtu_blackhole_detected: bool,
    pub blackhole_hop_ttl: Option<i32>,
    pub raw_data: DbJson,
}

impl HorizonPathHopRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "time": self.time,
            "round_id": self.round_id,
            "target_id": self.target_id,
            "pop_id": self.pop_id,
            "hop_ttl": self.hop_ttl,
            "hop_ip": self.hop_ip,
            "router_alias_id": self.router_alias_id,
            "alias_confidence": self.alias_confidence,
            "asn": self.asn,
            "as_org": self.as_org,
            "is_cloud": self.is_cloud,
            "cloud_provider": self.cloud_provider,
            "cloud_region": self.cloud_region,
            "forwarding_loss_pct": self.forwarding_loss_pct,
            "avg_rtt_ms": self.avg_rtt_ms,
            "effective_path_mtu": self.effective_path_mtu,
            "mtu_blackhole_detected": self.mtu_blackhole_detected,
            "blackhole_hop_ttl": self.blackhole_hop_ttl,
            "raw_data": self.raw_data,
        })
    }
}
