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

//! Deserialization rows and graph-traversal helpers for external topology
//! read-only queries.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};

use serde::Deserialize;

use crate::types::{ExternalEdgeRef, ExternalNodeRef};

pub(crate) struct Subgraph {
    pub(crate) nodes: BTreeMap<String, RawNode>,
    pub(crate) edges: Vec<ExternalEdgeRef>,
    pub(crate) peer_uids: HashSet<String>,
    pub(crate) truncated: bool,
}

/// Insert `node` into `nodes` and `next_frontier` if not already present and
/// `nodes.len() < limit`. Returns `true` when the node is present in `nodes`
/// (already present or newly inserted), `false` when dropped due to empty
/// UID or `limit` truncation.
pub(crate) fn add_node(
    node: RawNode,
    nodes: &mut BTreeMap<String, RawNode>,
    next_frontier: &mut Vec<String>,
    limit: usize,
    truncated: &mut bool,
) -> bool {
    if node.uid.is_empty() {
        return false;
    }
    if nodes.contains_key(&node.uid) {
        return true;
    }
    if nodes.len() >= limit {
        *truncated = true;
        return false;
    }
    let uid = node.uid.clone();
    nodes.insert(uid.clone(), node);
    next_frontier.push(uid);
    true
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn record_edge(
    src_id: &str,
    dst_id: &str,
    kind: &str,
    raw: &RawEdge,
    seen: &mut BTreeSet<String>,
    edges: &mut Vec<ExternalEdgeRef>,
    limit: usize,
    truncated: &mut bool,
) {
    if src_id.is_empty() || dst_id.is_empty() {
        return;
    }
    if !seen.insert(format!("{kind}|{src_id}|{dst_id}")) {
        return;
    }
    if edges.len() >= limit {
        *truncated = true;
        return;
    }
    edges.push(ExternalEdgeRef {
        src_id: src_id.to_string(),
        dst_id: dst_id.to_string(),
        kind: kind.to_string(),
        border_asn: raw.border_asn,
        as_boundary_confidence: raw.as_boundary_confidence,
        avg_rtt_us: raw.avg_rtt_us,
        loss_pct: raw.loss_pct,
        last_seen: raw.last_seen.clone(),
    });
}

pub(crate) fn record_simple_edge(
    src_id: &str,
    dst_id: &str,
    kind: &str,
    seen: &mut BTreeSet<String>,
    edges: &mut Vec<ExternalEdgeRef>,
    limit: usize,
    truncated: &mut bool,
) {
    let empty = RawEdge::default();
    record_edge(src_id, dst_id, kind, &empty, seen, edges, limit, truncated);
}

pub(crate) fn shortest_path_trace(
    graph: &Subgraph,
    seeds: &[RawNode],
    target_id: &str,
) -> (bool, usize, Vec<ExternalNodeRef>, Vec<ExternalEdgeRef>) {
    let mut by_id: HashMap<String, &RawNode> = HashMap::new();
    for node in graph.nodes.values() {
        let id = node.canonical_id();
        if !id.is_empty() {
            by_id.insert(id, node);
        }
    }
    let mut adj: HashMap<&str, Vec<&ExternalEdgeRef>> = HashMap::new();
    for edge in &graph.edges {
        adj.entry(edge.src_id.as_str()).or_default().push(edge);
        adj.entry(edge.dst_id.as_str()).or_default().push(edge);
    }

    let mut queue = VecDeque::new();
    let mut parent: HashMap<&str, (&str, &ExternalEdgeRef)> = HashMap::new();
    let mut visited = HashSet::new();
    for seed in seeds {
        let id = seed.canonical_id();
        if let Some((k, _)) = by_id.get_key_value(&id) {
            visited.insert(k.as_str());
            queue.push_back(k.as_str());
        }
    }

    let mut found_end: Option<&str> = None;
    while let Some(cur) = queue.pop_front() {
        if cur == target_id {
            found_end = Some(cur);
            break;
        }
        if let Some(list) = adj.get(cur) {
            for edge in list {
                let next = if edge.src_id == cur {
                    edge.dst_id.as_str()
                } else {
                    edge.src_id.as_str()
                };
                if visited.insert(next) {
                    parent.insert(next, (cur, *edge));
                    queue.push_back(next);
                }
            }
        }
    }

    let Some(mut cur) = found_end else {
        return (false, 0, Vec::new(), Vec::new());
    };
    let mut path_edges = Vec::new();
    let mut path_node_ids = vec![cur.to_string()];
    while let Some(&(prev, edge)) = parent.get(cur) {
        path_edges.push(edge.clone());
        path_node_ids.push(prev.to_string());
        cur = prev;
    }
    path_edges.reverse();
    path_node_ids.reverse();
    let nodes = path_node_ids
        .into_iter()
        .filter_map(|id| by_id.get(&id).map(|n| n.to_ref()))
        .collect();
    let hops = path_edges.len();
    (true, hops, nodes, path_edges)
}

pub(crate) fn dedup_raw_nodes(rows: Vec<RawNode>) -> Vec<RawNode> {
    let mut map = BTreeMap::new();
    for row in rows {
        if !row.uid.is_empty() {
            map.insert(row.uid.clone(), row);
        }
    }
    map.into_values().collect()
}

#[derive(Debug, Clone, Deserialize, Default)]
pub(crate) struct RawNode {
    #[serde(default)]
    pub(crate) uid: String,
    #[serde(default, rename = "dgraph.type")]
    pub(crate) dgraph_type: Vec<String>,
    #[serde(default, rename = "device.id")]
    pub(crate) device_id: Option<String>,
    #[serde(default, rename = "device.hostname")]
    pub(crate) hostname: Option<String>,
    #[serde(default, rename = "device.ip")]
    pub(crate) device_ip: Option<String>,
    #[serde(default, rename = "hop.ip")]
    pub(crate) hop_ip: Option<String>,
    #[serde(default, rename = "prefix.cidr")]
    pub(crate) prefix_cidr: Option<String>,
    #[serde(default, rename = "prefix.asn")]
    pub(crate) prefix_asn: Option<i64>,
    #[serde(default, rename = "prefix.rpki_state")]
    pub(crate) prefix_rpki_state: Option<String>,
    #[serde(default, rename = "prefix.rtbh_active")]
    pub(crate) prefix_rtbh_active: Option<bool>,
    #[serde(default, rename = "ext.id")]
    pub(crate) ext_id: Option<String>,
    #[serde(default, rename = "ext.kind")]
    pub(crate) ext_kind: Option<String>,
    #[serde(default, rename = "ext.asn")]
    pub(crate) ext_asn: Option<i64>,
    #[serde(default, rename = "ext.label")]
    pub(crate) label: Option<String>,
    #[serde(default, rename = "ext.region")]
    pub(crate) region: Option<String>,
    #[serde(default, rename = "ext.ip")]
    pub(crate) ext_ip: Option<String>,
    #[serde(default, rename = "ext.rpki_state")]
    pub(crate) ext_rpki_state: Option<String>,
    #[serde(default, rename = "ext.rtbh_active")]
    pub(crate) ext_rtbh_active: Option<bool>,
    #[serde(default, rename = "ext.outage_state")]
    pub(crate) outage_state: Option<String>,
    #[serde(default, rename = "ext.metro")]
    pub(crate) metro: Option<String>,
    #[serde(default, rename = "ext.iata")]
    pub(crate) iata: Option<String>,
    #[serde(default, rename = "ext.country_code")]
    pub(crate) country_code: Option<String>,
    #[serde(default, rename = "ext.stale")]
    pub(crate) stale: bool,
}

impl RawNode {
    pub(crate) fn canonical_id(&self) -> String {
        self.device_id
            .as_deref()
            .or(self.ext_id.as_deref())
            .or(self.prefix_cidr.as_deref())
            .or(self.hop_ip.as_deref())
            .unwrap_or(&self.uid)
            .to_string()
    }

    pub(crate) fn is_internal_device(&self) -> bool {
        self.device_id.is_some()
    }

    pub(crate) fn is_prefix(&self) -> bool {
        self.prefix_cidr.is_some()
    }

    pub(crate) fn kind(&self) -> &str {
        if self.device_id.is_some() {
            "Device"
        } else if let Some(kind) = self.ext_kind.as_deref() {
            kind
        } else if self.prefix_cidr.is_some() {
            "Prefix"
        } else if self.hop_ip.is_some() {
            "HopNode"
        } else {
            self.dgraph_type.first().map_or("Unknown", String::as_str)
        }
    }

    pub(crate) fn to_ref(&self) -> ExternalNodeRef {
        ExternalNodeRef {
            id: self.canonical_id(),
            kind: self.kind().to_string(),
            label: self.label.clone().or_else(|| self.hostname.clone()),
            asn: self.ext_asn.or(self.prefix_asn),
            region: self.region.clone(),
            ip: self
                .ext_ip
                .clone()
                .or_else(|| self.device_ip.clone())
                .or_else(|| self.hop_ip.clone()),
            rpki_state: self
                .ext_rpki_state
                .clone()
                .or_else(|| self.prefix_rpki_state.clone()),
            rtbh_active: self.ext_rtbh_active.or(self.prefix_rtbh_active),
            outage_state: self.outage_state.clone(),
            metro: self.metro.clone(),
            iata: self.iata.clone(),
            country_code: self.country_code.clone(),
        }
    }
}

#[derive(Debug, Deserialize, Default)]
pub(crate) struct RawEdge {
    #[serde(default, rename = "topo.kind")]
    pub(crate) kind: String,
    #[serde(default, rename = "topo.border_asn")]
    pub(crate) border_asn: Option<i64>,
    #[serde(default, rename = "topo.as_boundary_confidence")]
    pub(crate) as_boundary_confidence: Option<f64>,
    #[serde(default, rename = "topo.avg_rtt_us")]
    pub(crate) avg_rtt_us: Option<i64>,
    #[serde(default, rename = "topo.loss_pct")]
    pub(crate) loss_pct: Option<f64>,
    #[serde(default, rename = "topo.last_seen")]
    pub(crate) last_seen: Option<String>,
    #[serde(default, rename = "topo.src")]
    pub(crate) src: Vec<RawNode>,
    #[serde(default, rename = "topo.dst")]
    pub(crate) dst: Vec<RawNode>,
}

#[derive(Debug, Deserialize, Default)]
pub(crate) struct AsnsBlock {
    #[serde(default)]
    pub(crate) asns: Vec<RawNode>,
}

#[derive(Debug, Deserialize, Default)]
pub(crate) struct HopExpandBlock {
    #[serde(default)]
    pub(crate) q: Vec<HopExpandRow>,
}

#[derive(Debug, Deserialize, Default)]
pub(crate) struct HopExpandRow {
    #[serde(default)]
    pub(crate) uid: String,
    #[serde(default, rename = "~topo.src")]
    pub(crate) out_edges: Vec<RawEdge>,
    #[serde(default, rename = "~topo.dst")]
    pub(crate) in_edges: Vec<RawEdge>,
    #[serde(default, rename = "device.interfaces")]
    pub(crate) interfaces: Vec<IfacePrefixes>,
    #[serde(default, rename = "~iface.prefixes")]
    pub(crate) rev_ifaces: Vec<IfaceDevices>,
}

#[derive(Debug, Deserialize, Default)]
pub(crate) struct IfacePrefixes {
    #[serde(default, rename = "iface.prefixes")]
    pub(crate) prefixes: Vec<RawNode>,
}

#[derive(Debug, Deserialize, Default)]
pub(crate) struct IfaceDevices {
    #[serde(default, rename = "~device.interfaces")]
    pub(crate) devices: Vec<RawNode>,
}

#[derive(Debug, Deserialize, Default)]
pub(crate) struct PrefixConeBlock {
    #[serde(default)]
    pub(crate) prefixes: Vec<PrefixConeRow>,
}

#[derive(Debug, Deserialize, Default)]
pub(crate) struct PrefixConeRow {
    #[serde(flatten)]
    pub(crate) node: RawNode,
    #[serde(default, rename = "~iface.prefixes")]
    pub(crate) rev_ifaces: Vec<IfaceDevices>,
}
