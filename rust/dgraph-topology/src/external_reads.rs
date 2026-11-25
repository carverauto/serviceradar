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

//! Bounded read-only multi-hop DQL queries across stitched internal
//! (`Device`/`HopNode`/`Prefix`) and external Horizon topology vertices.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use dgraph_client::{ReadOnly, Txn};
use serde::Deserialize;

use crate::client::{TopologyClient, dql_string};
use crate::errors::TopologyError;
use crate::external_rows::{
    AsnsBlock, HopExpandBlock, PrefixConeBlock, RawNode, Subgraph, add_node, dedup_raw_nodes,
    record_edge, record_simple_edge, shortest_path_trace,
};
use crate::types::{
    BlastRadiusResult, CustomerConeResult, ExternalEdgeRef, MultiHopTraceResult, clamp_max_hops,
    clamp_query_limit,
};

pub(crate) const NODE_FIELDS: &str = "uid dgraph.type device.id device.hostname device.ip hop.ip \
  prefix.cidr prefix.asn prefix.rpki_state prefix.rtbh_active \
  ext.id ext.kind ext.asn ext.label ext.region ext.ip ext.rpki_state \
  ext.rtbh_active ext.outage_state ext.metro ext.iata ext.country_code ext.stale";
pub(crate) const EDGE_BODY: &str = "topo.kind topo.border_asn topo.as_boundary_confidence \
  topo.avg_rtt_us topo.loss_pct topo.last_seen";

impl TopologyClient {
    /// Compute bounded inside-to-outside blast radius from `seed_id`
    /// (`max_hops` clamped `1..=8`, `limit` clamped `1..=200`).
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if `seed_id` is empty or a Dgraph query fails.
    pub async fn query_blast_radius(
        &self,
        seed_id: &str,
        max_hops: u8,
        limit: usize,
    ) -> Result<BlastRadiusResult, TopologyError> {
        let seed = require_nonempty_id(seed_id, "seed_id")?;
        let hops = clamp_max_hops(max_hops);
        let cap = clamp_query_limit(limit);
        let mut txn = self.dgraph().new_read_only_txn();
        let seeds = resolve_seed_nodes(&mut txn, seed).await?;
        let graph = expand_subgraph(&mut txn, &seeds, hops, cap).await?;

        let mut internal_devices = Vec::new();
        let mut prefixes = Vec::new();
        let mut external_nodes = Vec::new();
        for node in graph.nodes.values() {
            if node.is_internal_device() {
                internal_devices.push(node.to_ref());
            } else if node.is_prefix() {
                prefixes.push(node.to_ref());
            } else {
                external_nodes.push(node.to_ref());
            }
        }

        Ok(BlastRadiusResult {
            seed_id: seed.to_string(),
            max_hops: hops,
            truncated: graph.truncated,
            internal_devices,
            prefixes,
            external_nodes,
            edges: graph.edges,
        })
    }

    /// Compute bounded BGP customer-cone impact from `asn_id` (`max_hops`
    /// clamped `1..=8`, `limit` clamped `1..=200`).
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if `asn_id` is empty or a Dgraph query fails.
    pub async fn query_customer_cone(
        &self,
        asn_id: &str,
        max_hops: u8,
        limit: usize,
    ) -> Result<CustomerConeResult, TopologyError> {
        let raw = require_nonempty_id(asn_id, "asn_id")?;
        let hops = clamp_max_hops(max_hops);
        let cap = clamp_query_limit(limit);
        let mut txn = self.dgraph().new_read_only_txn();
        let asn_num = parse_asn_number(raw);
        let seeds = resolve_asn_seeds(&mut txn, raw, asn_num).await?;
        let graph = expand_customer_cone(&mut txn, &seeds, asn_num, hops, cap).await?;

        let mut customer_asns = Vec::new();
        let mut peer_asns = Vec::new();
        let mut prefixes = Vec::new();
        let mut impacted_devices = Vec::new();
        let mut saas_targets = Vec::new();

        for (uid, node) in &graph.nodes {
            if seeds.iter().any(|s| s.uid == *uid) {
                continue;
            }
            if node.is_internal_device() {
                impacted_devices.push(node.to_ref());
            } else if node.is_prefix() {
                prefixes.push(node.to_ref());
            } else if node.kind() == "SaasTarget" {
                saas_targets.push(node.to_ref());
            } else if node.kind() == "ASN" {
                if graph.peer_uids.contains(uid) {
                    peer_asns.push(node.to_ref());
                } else {
                    customer_asns.push(node.to_ref());
                }
            }
        }

        Ok(CustomerConeResult {
            asn_id: raw.to_string(),
            max_hops: hops,
            truncated: graph.truncated,
            customer_asns,
            peer_asns,
            prefixes,
            impacted_devices,
            saas_targets,
            edges: graph.edges,
        })
    }

    /// Bounded multi-hop inside-to-outside trace from `src_id` (optionally
    /// shortest-path filtered to `dst_id`).
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if `src_id` is empty or a Dgraph query fails.
    pub async fn query_multi_hop_trace(
        &self,
        src_id: &str,
        dst_id: Option<&str>,
        max_hops: u8,
        limit: usize,
    ) -> Result<MultiHopTraceResult, TopologyError> {
        let src = require_nonempty_id(src_id, "src_id")?;
        let dst = dst_id.map(str::trim).filter(|s| !s.is_empty());
        let hops = clamp_max_hops(max_hops);
        let cap = clamp_query_limit(limit);
        let mut txn = self.dgraph().new_read_only_txn();
        let seeds = resolve_seed_nodes(&mut txn, src).await?;
        let graph = expand_subgraph(&mut txn, &seeds, hops, cap).await?;

        if let Some(target_id) = dst {
            let (found, path_hops, nodes, edges) = shortest_path_trace(&graph, &seeds, target_id);
            return Ok(MultiHopTraceResult {
                src_id: src.to_string(),
                dst_id: Some(target_id.to_string()),
                max_hops: hops,
                found,
                hops: path_hops,
                nodes,
                edges,
            });
        }

        let nodes: Vec<_> = graph.nodes.values().map(RawNode::to_ref).collect();
        let edge_count = graph.edges.len();
        Ok(MultiHopTraceResult {
            src_id: src.to_string(),
            dst_id: None,
            max_hops: hops,
            found: !nodes.is_empty(),
            hops: edge_count.min(hops),
            nodes,
            edges: graph.edges,
        })
    }
}

fn require_nonempty_id<'a>(val: &'a str, name: &str) -> Result<&'a str, TopologyError> {
    let trimmed = val.trim();
    if trimmed.is_empty() {
        return Err(TopologyError::InvalidValue(format!(
            "{name} must not be empty"
        )));
    }
    Ok(trimmed)
}

fn parse_asn_number(raw: &str) -> Option<i64> {
    let s = raw.trim();
    let stripped = s
        .strip_prefix("asn:")
        .or_else(|| s.strip_prefix("AS"))
        .or_else(|| s.strip_prefix("as"))
        .unwrap_or(s);
    stripped.parse::<i64>().ok().filter(|&n| n > 0)
}

pub(crate) async fn ro_query<T>(txn: &mut Txn<ReadOnly>, query: &str) -> Result<T, TopologyError>
where
    T: for<'de> Deserialize<'de>,
{
    let resp = txn
        .query(query)
        .await
        .map_err(|err| TopologyError::from_dgraph(&err))?;
    serde_json::from_slice(resp.json()).map_err(|err| TopologyError::Serde(err.to_string()))
}

async fn resolve_seed_nodes(
    txn: &mut Txn<ReadOnly>,
    seed: &str,
) -> Result<Vec<RawNode>, TopologyError> {
    let q = dql_string(seed);
    let mut blocks = format!(
        "  a(func: eq(device.id, {q})) {{ {NODE_FIELDS} }}
  b(func: eq(hop.ip, {q})) {{ {NODE_FIELDS} }}
  c(func: eq(prefix.cidr, {q})) {{ {NODE_FIELDS} }}
  d(func: eq(ext.id, {q})) @filter(NOT eq(ext.stale, true)) {{ {NODE_FIELDS} }}
  e(func: eq(device.ip, {q})) {{ {NODE_FIELDS} }}
  f(func: eq(ext.ip, {q})) @filter(NOT eq(ext.stale, true)) {{ {NODE_FIELDS} }}"
    );
    if let Some(asn) = parse_asn_number(seed) {
        blocks.push_str(&format!(
            "\n  g(func: eq(ext.asn, {asn})) @filter(eq(ext.kind, \"ASN\") AND NOT eq(ext.stale, true)) {{ {NODE_FIELDS} }}"
        ));
    }
    let query = format!("{{\n{blocks}\n}}");
    let map: BTreeMap<String, Vec<RawNode>> = ro_query(txn, &query).await?;
    Ok(dedup_raw_nodes(map.into_values().flatten().collect()))
}

async fn resolve_asn_seeds(
    txn: &mut Txn<ReadOnly>,
    raw: &str,
    asn_num: Option<i64>,
) -> Result<Vec<RawNode>, TopologyError> {
    let q = dql_string(raw);
    let mut blocks = format!(
        "  a(func: eq(ext.id, {q})) @filter(NOT eq(ext.stale, true)) {{ {NODE_FIELDS} }}"
    );
    if let Some(asn) = asn_num {
        blocks.push_str(&format!(
            "\n  b(func: eq(ext.asn, {asn})) @filter(eq(ext.kind, \"ASN\") AND NOT eq(ext.stale, true)) {{ {NODE_FIELDS} }}"
        ));
    }
    let query = format!("{{\n{blocks}\n}}");
    let map: BTreeMap<String, Vec<RawNode>> = ro_query(txn, &query).await?;
    Ok(dedup_raw_nodes(map.into_values().flatten().collect()))
}

async fn expand_subgraph(
    txn: &mut Txn<ReadOnly>,
    seeds: &[RawNode],
    max_hops: usize,
    limit: usize,
) -> Result<Subgraph, TopologyError> {
    let mut nodes: BTreeMap<String, RawNode> = BTreeMap::new();
    let mut seen_edges: BTreeSet<String> = BTreeSet::new();
    let mut edges = Vec::new();
    let mut frontier: Vec<String> = Vec::new();
    let mut truncated = false;

    for s in seeds {
        if nodes.len() >= limit {
            truncated = true;
            break;
        }
        if !s.uid.is_empty() && nodes.insert(s.uid.clone(), s.clone()).is_none() {
            frontier.push(s.uid.clone());
        }
    }

    for _depth in 0..max_hops {
        if frontier.is_empty() || nodes.len() >= limit || edges.len() >= limit {
            if !frontier.is_empty() {
                truncated = true;
            }
            break;
        }
        let uids = frontier.join(", ");
        let query = format!(
            "{{\n  q(func: uid({uids})) {{\n    uid\n    ~topo.src @filter(NOT eq(topo.stale, true)) {{ {EDGE_BODY} topo.dst {{ {NODE_FIELDS} }} }}\n    ~topo.dst @filter(NOT eq(topo.stale, true)) {{ {EDGE_BODY} topo.src {{ {NODE_FIELDS} }} }}\n    device.interfaces {{ iface.prefixes {{ {NODE_FIELDS} }} }}\n    ~iface.prefixes {{ ~device.interfaces {{ {NODE_FIELDS} }} }}\n  }}\n}}"
        );
        let parsed: HopExpandBlock = ro_query(txn, &query).await?;
        let mut next_frontier = Vec::new();

        for row in parsed.q {
            let Some(src_node) = nodes.get(&row.uid).cloned() else {
                continue;
            };
            let src_id = src_node.canonical_id();
            for e in row.out_edges {
                for dst_node in e.dst.iter().filter(|n| !n.stale).cloned() {
                    let dst_id = dst_node.canonical_id();
                    if add_node(dst_node, &mut nodes, &mut next_frontier, limit, &mut truncated) {
                        record_edge(&src_id, &dst_id, &e.kind, &e, &mut seen_edges, &mut edges, limit, &mut truncated);
                    }
                }
            }
            for e in row.in_edges {
                for far_node in e.src.iter().filter(|n| !n.stale).cloned() {
                    let far_id = far_node.canonical_id();
                    if add_node(far_node, &mut nodes, &mut next_frontier, limit, &mut truncated) {
                        record_edge(&far_id, &src_id, &e.kind, &e, &mut seen_edges, &mut edges, limit, &mut truncated);
                    }
                }
            }
            for iface in row.interfaces {
                for pfx in iface.prefixes {
                    let pfx_id = pfx.canonical_id();
                    if add_node(pfx, &mut nodes, &mut next_frontier, limit, &mut truncated) {
                        record_simple_edge(&src_id, &pfx_id, "INTERFACE_PREFIX", &mut seen_edges, &mut edges, limit, &mut truncated);
                    }
                }
            }
            for rev_iface in row.rev_ifaces {
                for dev in rev_iface.devices {
                    let dev_id = dev.canonical_id();
                    if add_node(dev, &mut nodes, &mut next_frontier, limit, &mut truncated) {
                        record_simple_edge(&dev_id, &src_id, "INTERFACE_PREFIX", &mut seen_edges, &mut edges, limit, &mut truncated);
                    }
                }
            }
        }
        bridge_prefix_asns(
            txn,
            &frontier,
            &mut nodes,
            &mut next_frontier,
            &mut seen_edges,
            &mut edges,
            limit,
            &mut truncated,
        )
        .await?;
        frontier = next_frontier;
    }

    Ok(Subgraph {
        nodes,
        edges,
        peer_uids: HashSet::new(),
        truncated,
    })
}

#[allow(clippy::too_many_arguments)]
async fn bridge_prefix_asns(
    txn: &mut Txn<ReadOnly>,
    frontier: &[String],
    nodes: &mut BTreeMap<String, RawNode>,
    next_frontier: &mut Vec<String>,
    seen_edges: &mut BTreeSet<String>,
    edges: &mut Vec<ExternalEdgeRef>,
    limit: usize,
    truncated: &mut bool,
) -> Result<(), TopologyError> {
    if nodes.len() >= limit || edges.len() >= limit {
        return Ok(());
    }
    let mut prefix_asns: Vec<(String, i64)> = Vec::new();
    let mut wanted_asns = BTreeSet::new();
    for uid in frontier {
        if let Some(node) = nodes.get(uid)
            && node.is_prefix()
            && let Some(asn) = node.prefix_asn.filter(|&a| a > 0)
        {
            prefix_asns.push((node.canonical_id(), asn));
            wanted_asns.insert(asn);
        }
    }
    if wanted_asns.is_empty() {
        return Ok(());
    }

    let asn_list = wanted_asns
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(", ");
    let query = format!(
        "{{\n  asns(func: eq(ext.asn, [{asn_list}]), first: {limit}) \
         @filter(eq(ext.kind, \"ASN\") AND NOT eq(ext.stale, true)) {{ {NODE_FIELDS} }}\n}}"
    );
    let parsed: AsnsBlock = ro_query(txn, &query).await?;
    let mut by_asn: HashMap<i64, Vec<RawNode>> = HashMap::new();
    for asn_node in parsed.asns {
        if !asn_node.stale
            && let Some(asn) = asn_node.ext_asn
        {
            by_asn.entry(asn).or_default().push(asn_node);
        }
    }

    for (pfx_id, asn) in prefix_asns {
        if let Some(asn_nodes) = by_asn.get(&asn) {
            for asn_node in asn_nodes {
                let asn_id = asn_node.canonical_id();
                if add_node(asn_node.clone(), nodes, next_frontier, limit, truncated) {
                    record_simple_edge(
                        &asn_id,
                        &pfx_id,
                        "ORIGIN_PREFIX",
                        seen_edges,
                        edges,
                        limit,
                        truncated,
                    );
                }
            }
        }
    }
    Ok(())
}

async fn expand_customer_cone(
    txn: &mut Txn<ReadOnly>,
    seeds: &[RawNode],
    asn_num: Option<i64>,
    max_hops: usize,
    limit: usize,
) -> Result<Subgraph, TopologyError> {
    let mut nodes: BTreeMap<String, RawNode> = BTreeMap::new();
    let mut seen_edges: BTreeSet<String> = BTreeSet::new();
    let mut edges = Vec::new();
    let mut peer_uids = HashSet::new();
    let mut frontier = Vec::new();
    let mut truncated = false;

    for s in seeds {
        if nodes.len() >= limit {
            truncated = true;
            break;
        }
        if !s.uid.is_empty() && nodes.insert(s.uid.clone(), s.clone()).is_none() {
            frontier.push(s.uid.clone());
        }
    }

    if let Some(asn) = asn_num {
        let query = format!(
            "{{\n  prefixes(func: eq(prefix.asn, {asn}), first: {limit}) {{ {NODE_FIELDS} ~iface.prefixes {{ ~device.interfaces {{ {NODE_FIELDS} }} }} }}\n}}"
        );
        let parsed: PrefixConeBlock = ro_query(txn, &query).await?;
        for pfx in parsed.prefixes {
            let pfx_id = pfx.node.canonical_id();
            if !add_node(pfx.node, &mut nodes, &mut frontier, limit, &mut truncated) {
                continue;
            }
            if let Some(seed) = seeds.first().filter(|s| nodes.contains_key(&s.uid)) {
                record_simple_edge(&seed.canonical_id(), &pfx_id, "ORIGIN_PREFIX", &mut seen_edges, &mut edges, limit, &mut truncated);
            }
            for iface in pfx.rev_ifaces {
                for dev in iface.devices {
                    let dev_id = dev.canonical_id();
                    if add_node(dev, &mut nodes, &mut frontier, limit, &mut truncated) {
                        record_simple_edge(&dev_id, &pfx_id, "INTERFACE_PREFIX", &mut seen_edges, &mut edges, limit, &mut truncated);
                    }
                }
            }
        }
    }

    for depth in 0..max_hops {
        if frontier.is_empty() || nodes.len() >= limit || edges.len() >= limit {
            if !frontier.is_empty() {
                truncated = true;
            }
            break;
        }
        let uids = frontier.join(", ");
        let query = format!(
            "{{\n  q(func: uid({uids})) {{\n    uid\n    ~topo.src @filter(NOT eq(topo.stale, true) AND eq(topo.kind, [\"AS_REL_PROVIDER\", \"AS_REL_PEER\", \"IXP_MEMBER\", \"ANYCAST_SERVES\", \"BORDER_HANDOFF\", \"TRACEROUTE_HOP\"])) {{ {EDGE_BODY} topo.dst {{ {NODE_FIELDS} }} }}\n  }}\n}}"
        );
        let parsed: HopExpandBlock = ro_query(txn, &query).await?;
        let mut next_frontier = Vec::new();
        for row in parsed.q {
            let Some(src_node) = nodes.get(&row.uid).cloned() else {
                continue;
            };
            let src_id = src_node.canonical_id();
            for e in row.out_edges {
                if e.kind == "AS_REL_PEER" && depth > 0 {
                    continue;
                }
                for dst_node in e.dst.iter().filter(|n| !n.stale).cloned() {
                    let is_peer = e.kind == "AS_REL_PEER";
                    let dst_uid = dst_node.uid.clone();
                    let dst_id = dst_node.canonical_id();
                    if add_node(dst_node, &mut nodes, &mut next_frontier, limit, &mut truncated) {
                        if is_peer {
                            peer_uids.insert(dst_uid);
                        }
                        record_edge(&src_id, &dst_id, &e.kind, &e, &mut seen_edges, &mut edges, limit, &mut truncated);
                    }
                }
            }
        }
        frontier = next_frontier;
    }

    Ok(Subgraph {
        nodes,
        edges,
        peer_uids,
        truncated,
    })
}
