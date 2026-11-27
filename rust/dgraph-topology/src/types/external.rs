/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Typed external Horizon topology entities, collapsed edges, and bounded
//! multi-hop query results.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::types::link_key;

pub const DEFAULT_MAX_HOPS: u8 = 4;
pub const MAX_ALLOWED_HOPS: u8 = 8;
pub const DEFAULT_QUERY_LIMIT: usize = 50;
pub const MAX_QUERY_LIMIT: usize = 200;
pub const DEFAULT_EGRESS_TARGETS_LIMIT: usize = 1000;
pub const MAX_EGRESS_TARGETS_LIMIT: usize = 5000;

/// Clamp multi-hop traversal depth to `1..=8`.
#[must_use]
pub fn clamp_max_hops(max_hops: u8) -> usize {
    if max_hops == 0 {
        usize::from(DEFAULT_MAX_HOPS)
    } else {
        usize::from(max_hops.min(MAX_ALLOWED_HOPS))
    }
}

/// Clamp query result limit to `1..=200`.
#[must_use]
pub fn clamp_query_limit(limit: usize) -> usize {
    if limit == 0 {
        DEFAULT_QUERY_LIMIT
    } else {
        limit.min(MAX_QUERY_LIMIT)
    }
}

/// External entity types from Horizon topology snapshots (`Contract #4`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ExternalNodeKind {
    Vantage,
    TransitRouter,
    Ixp,
    Facility,
    Asn,
    Prefix,
    AnycastPop,
    SaasTarget,
}

impl ExternalNodeKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Vantage => "Vantage",
            Self::TransitRouter => "TransitRouter",
            Self::Ixp => "IXP",
            Self::Facility => "Facility",
            Self::Asn => "ASN",
            Self::Prefix => "Prefix",
            Self::AnycastPop => "AnycastPop",
            Self::SaasTarget => "SaasTarget",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "vantage" => Some(Self::Vantage),
            "transitrouter" | "transit_router" => Some(Self::TransitRouter),
            "ixp" => Some(Self::Ixp),
            "facility" => Some(Self::Facility),
            "asn" => Some(Self::Asn),
            "prefix" => Some(Self::Prefix),
            "anycastpop" | "anycast_pop" => Some(Self::AnycastPop),
            "saastarget" | "saas_target" => Some(Self::SaasTarget),
            _ => None,
        }
    }
}

/// Collapsed/deduplicated external topology edge kinds (`Contract #4`).
/// Never overlaps with `CANONICAL_TOPOLOGY`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ExternalEdgeKind {
    TracerouteHop,
    BorderHandoff,
    AsRelProvider,
    AsRelPeer,
    IxpMember,
    AnycastServes,
    EgressesTo,
}

impl ExternalEdgeKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TracerouteHop => "TRACEROUTE_HOP",
            Self::BorderHandoff => "BORDER_HANDOFF",
            Self::AsRelProvider => "AS_REL_PROVIDER",
            Self::AsRelPeer => "AS_REL_PEER",
            Self::IxpMember => "IXP_MEMBER",
            Self::AnycastServes => "ANYCAST_SERVES",
            Self::EgressesTo => "EGRESSES_TO",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "traceroute_hop" => Some(Self::TracerouteHop),
            "border_handoff" => Some(Self::BorderHandoff),
            "as_rel_provider" => Some(Self::AsRelProvider),
            "as_rel_peer" => Some(Self::AsRelPeer),
            "ixp_member" => Some(Self::IxpMember),
            "anycast_serves" => Some(Self::AnycastServes),
            "egresses_to" => Some(Self::EgressesTo),
            _ => None,
        }
    }
}

/// External node upsert payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalNodeWrite {
    pub id: String,
    pub kind: ExternalNodeKind,
    pub asn: Option<i64>,
    pub label: Option<String>,
    pub region: Option<String>,
    pub ip: Option<String>,
    pub rpki_state: Option<String>,
    pub rtbh_active: Option<bool>,
    pub max_length: Option<i64>,
    pub irr_status: Option<String>,
    pub metro: Option<String>,
    pub iata: Option<String>,
    pub country_code: Option<String>,
    pub outage_state: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port_speed_mbps: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ingestor: Option<String>,
    pub last_seen: String,
    pub expires_at: Option<String>,
}

/// Collapsed/deduplicated external edge upsert payload.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExternalEdgeWrite {
    pub src_id: String,
    pub dst_id: String,
    pub kind: ExternalEdgeKind,
    pub border_asn: Option<i64>,
    pub as_boundary_confidence: Option<f64>,
    pub avg_rtt_us: Option<i64>,
    pub loss_pct: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port_speed_mbps: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub if_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub if_index: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub egress_source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ingestor: Option<String>,
    pub last_seen: String,
    pub ttl_secs: Option<i64>,
    pub expires_at: Option<String>,
}

impl ExternalEdgeWrite {
    /// Deterministic collapsed key `{KIND}|{src_id}|{dst_id}||` (never per-round).
    #[must_use]
    pub fn link_key(&self) -> String {
        link_key(self.kind.as_str(), &self.src_id, &self.dst_id, "", "")
    }
}

/// External topology snapshot upsert batch.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExternalSnapshotWrite {
    pub generated_at: String,
    pub ttl_secs: u64,
    pub nodes: Vec<ExternalNodeWrite>,
    pub edges: Vec<ExternalEdgeWrite>,
}

impl ExternalSnapshotWrite {
    /// Deduplicate nodes by `id` and collapse edges by `link_key` (latest wins).
    #[must_use]
    pub fn deduped(&self) -> Self {
        let mut node_map = BTreeMap::new();
        for node in &self.nodes {
            if !node.id.trim().is_empty() {
                node_map.insert(node.id.clone(), node.clone());
            }
        }
        let mut edge_map = BTreeMap::new();
        for edge in &self.edges {
            if !edge.src_id.trim().is_empty() && !edge.dst_id.trim().is_empty() {
                edge_map.insert(edge.link_key(), edge.clone());
            }
        }
        Self {
            generated_at: self.generated_at.clone(),
            ttl_secs: self.ttl_secs,
            nodes: node_map.into_values().collect(),
            edges: edge_map.into_values().collect(),
        }
    }
}

/// Incremental status patch for `serviceradar.horizon.outages.*` / `bgp.*`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalStatusPatch {
    pub entity_id: String,
    pub kind: Option<ExternalNodeKind>,
    pub outage_state: Option<String>,
    pub rpki_state: Option<String>,
    pub rtbh_active: Option<bool>,
    pub last_seen: String,
    pub expires_at: Option<String>,
}

/// Summary counters returned from `upsert_external_topology`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalUpsertStats {
    pub nodes_upserted: usize,
    pub edges_upserted: usize,
    pub edges_skipped: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalNodeRef {
    pub id: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub asn: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rpki_state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtbh_active: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outage_state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port_speed_mbps: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metro: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub iata: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub country_code: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExternalEdgeRef {
    pub src_id: String,
    pub dst_id: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub border_asn: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub as_boundary_confidence: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avg_rtt_us: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub loss_pct: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port_speed_mbps: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub if_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub if_index: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub egress_source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BlastRadiusResult {
    pub seed_id: String,
    pub max_hops: usize,
    pub truncated: bool,
    pub internal_devices: Vec<ExternalNodeRef>,
    pub prefixes: Vec<ExternalNodeRef>,
    pub external_nodes: Vec<ExternalNodeRef>,
    pub edges: Vec<ExternalEdgeRef>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SharedFateSpof {
    pub id: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub asn: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outage_state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port_speed_mbps: Option<i64>,
    pub target_count: usize,
    pub device_count: usize,
    pub targets: Vec<String>,
    pub devices: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CustomerConeResult {
    pub asn_id: String,
    pub max_hops: usize,
    pub truncated: bool,
    pub customer_asns: Vec<ExternalNodeRef>,
    pub peer_asns: Vec<ExternalNodeRef>,
    pub prefixes: Vec<ExternalNodeRef>,
    pub impacted_devices: Vec<ExternalNodeRef>,
    pub saas_targets: Vec<ExternalNodeRef>,
    pub edges: Vec<ExternalEdgeRef>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MultiHopTraceResult {
    pub src_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dst_id: Option<String>,
    pub max_hops: usize,
    pub found: bool,
    pub hops: usize,
    pub nodes: Vec<ExternalNodeRef>,
    pub edges: Vec<ExternalEdgeRef>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EgressDeviceRef {
    pub id: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub if_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub if_index: Option<i64>,
    pub egress_source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port_speed_mbps: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EgressTopologyResult {
    pub max_hops: usize,
    pub truncated: bool,
    pub egress_devices: Vec<EgressDeviceRef>,
    pub external_nodes: Vec<ExternalNodeRef>,
    pub edges: Vec<ExternalEdgeRef>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalEgressTargetsResult {
    pub prefixes: Vec<ExternalNodeRef>,
    pub asns: Vec<ExternalNodeRef>,
    pub vantages: Vec<ExternalNodeRef>,
}
