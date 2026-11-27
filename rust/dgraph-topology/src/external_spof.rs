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

//! Paged shared-fate SPOF detection across Horizon external edges, MTR paths,
//! canonical internal edges, and `Device -> Interface -> Prefix` links.

use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};

use dgraph_client::{ReadOnly, Txn};
use serde::Deserialize;

use crate::canonical_read::next_uid;
use crate::client::TopologyClient;
use crate::errors::TopologyError;
use crate::external_reads::{EDGE_BODY, NODE_FIELDS, ro_query};
use crate::external_rows::{IfaceDevices, RawNode};
use crate::types::{SharedFateSpof, clamp_query_limit};

const SPOF_PAGE_SIZE: usize = 500;
const MAX_EXTERNAL_SPOF_PAGES: usize = 20;
const MAX_CANONICAL_SPOF_PAGES: usize = 10;
const MAX_PREFIX_SPOF_PAGES: usize = 20;

const EXTERNAL_SPOF_EDGE_FILTER: &str = "NOT eq(topo.stale, true) AND eq(topo.kind, \
  [\"TRACEROUTE_HOP\", \"BORDER_HANDOFF\", \"AS_REL_PROVIDER\", \"AS_REL_PEER\", \
  \"IXP_MEMBER\", \"ANYCAST_SERVES\", \"MTR_PATH\", \"EGRESSES_TO\"])";
const CANONICAL_SPOF_EDGE_FILTER: &str =
    "NOT eq(topo.stale, true) AND eq(topo.kind, \"CANONICAL_TOPOLOGY\")";

impl TopologyClient {
    /// Identify external transit/IXP/facility/ASN bottlenecks shared across
    /// `>= min_targets` active paths (`limit` clamped `1..=200`).
    ///
    /// External/MTR edges are paged independently from `CANONICAL_TOPOLOGY`
    /// edges so large canonical graphs never truncate external bottlenecks, and
    /// `Device -> Interface -> Prefix` attachments are included when computing
    /// affected internal devices.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if a Dgraph query fails.
    pub async fn query_shared_fate_spofs(
        &self,
        min_targets: usize,
        limit: usize,
    ) -> Result<Vec<SharedFateSpof>, TopologyError> {
        let min_t = min_targets.max(1);
        let cap = clamp_query_limit(limit);
        let mut txn = self.dgraph().new_read_only_txn();

        let mut edges =
            fetch_spof_edges_paged(&mut txn, EXTERNAL_SPOF_EDGE_FILTER, MAX_EXTERNAL_SPOF_PAGES)
                .await?;
        let canonical = fetch_spof_edges_paged(
            &mut txn,
            CANONICAL_SPOF_EDGE_FILTER,
            MAX_CANONICAL_SPOF_PAGES,
        )
        .await?;
        edges.extend(canonical);

        let device_prefix_links = fetch_device_prefix_links_paged(&mut txn).await?;
        Ok(compute_shared_fate_spofs(
            &edges,
            &device_prefix_links,
            min_t,
            cap,
        ))
    }
}

async fn fetch_spof_edges_paged(
    txn: &mut Txn<ReadOnly>,
    filter: &str,
    max_pages: usize,
) -> Result<Vec<RawEdgeWithEnds>, TopologyError> {
    let mut all = Vec::new();
    let mut after = 0u64;
    for _ in 0..max_pages {
        let cursor = cursor_clause(after);
        let query = format!(
            "{{\n  edges(func: type(TopologyEdge), first: {SPOF_PAGE_SIZE}{cursor}) \
             @filter({filter}) {{\n    uid\n    {EDGE_BODY}\n    topo.src {{ {NODE_FIELDS} }}\n    topo.dst {{ {NODE_FIELDS} }}\n  }}\n}}"
        );
        let parsed: EdgesBlock = ro_query(txn, &query).await?;
        let count = parsed.edges.len();
        if count >= SPOF_PAGE_SIZE {
            for row in &parsed.edges {
                after = next_uid(&row.uid, after)?;
            }
        }
        all.extend(parsed.edges);
        if count < SPOF_PAGE_SIZE {
            break;
        }
    }
    Ok(all)
}

async fn fetch_device_prefix_links_paged(
    txn: &mut Txn<ReadOnly>,
) -> Result<Vec<(RawNode, RawNode)>, TopologyError> {
    let mut links = Vec::new();
    let mut after = 0u64;
    for _ in 0..MAX_PREFIX_SPOF_PAGES {
        let cursor = cursor_clause(after);
        let query = format!(
            "{{\n  prefixes(func: type(Prefix), first: {SPOF_PAGE_SIZE}{cursor}) \
             @filter(has(~iface.prefixes)) {{\n    {NODE_FIELDS}\n    ~iface.prefixes {{ ~device.interfaces {{ {NODE_FIELDS} }} }}\n  }}\n}}"
        );
        let parsed: SpofPrefixesBlock = ro_query(txn, &query).await?;
        let count = parsed.prefixes.len();
        if count >= SPOF_PAGE_SIZE {
            for row in &parsed.prefixes {
                after = next_uid(&row.node.uid, after)?;
            }
        }
        for row in parsed.prefixes {
            if row.node.stale || row.node.canonical_id().is_empty() {
                continue;
            }
            for rev_iface in row.rev_ifaces {
                for dev in rev_iface.devices {
                    if !dev.stale && !dev.canonical_id().is_empty() {
                        links.push((dev, row.node.clone()));
                    }
                }
            }
        }
        if count < SPOF_PAGE_SIZE {
            break;
        }
    }
    Ok(links)
}

fn cursor_clause(after: u64) -> String {
    if after == 0 {
        String::new()
    } else {
        format!(", after: {after:#x}")
    }
}

pub(crate) fn compute_shared_fate_spofs(
    edges: &[RawEdgeWithEnds],
    device_prefix_links: &[(RawNode, RawNode)],
    min_targets: usize,
    limit: usize,
) -> Vec<SharedFateSpof> {
    let mut node_map: HashMap<String, RawNode> = HashMap::new();
    let mut adj: HashMap<String, Vec<String>> = HashMap::new();
    let mut rev: HashMap<String, Vec<String>> = HashMap::new();
    let mut min_edge_speed: HashMap<String, i64> = HashMap::new();

    for edge in edges {
        let (Some(src), Some(dst)) = (edge.src.first(), edge.dst.first()) else {
            continue;
        };
        if src.stale || dst.stale {
            continue;
        }
        let sid = src.canonical_id();
        let did = dst.canonical_id();
        if sid.is_empty() || did.is_empty() {
            continue;
        }
        if let Some(speed) = edge.port_speed_mbps.filter(|&v| v > 0) {
            min_edge_speed
                .entry(sid.clone())
                .and_modify(|cur| *cur = (*cur).min(speed))
                .or_insert(speed);
            min_edge_speed
                .entry(did.clone())
                .and_modify(|cur| *cur = (*cur).min(speed))
                .or_insert(speed);
        }
        node_map.entry(sid.clone()).or_insert_with(|| src.clone());
        node_map.entry(did.clone()).or_insert_with(|| dst.clone());
        adj.entry(sid.clone()).or_default().push(did.clone());
        rev.entry(did).or_default().push(sid);
    }

    for (dev, pfx) in device_prefix_links {
        if dev.stale || pfx.stale {
            continue;
        }
        let dev_id = dev.canonical_id();
        let pfx_id = pfx.canonical_id();
        if dev_id.is_empty() || pfx_id.is_empty() {
            continue;
        }
        node_map
            .entry(dev_id.clone())
            .or_insert_with(|| dev.clone());
        node_map
            .entry(pfx_id.clone())
            .or_insert_with(|| pfx.clone());
        adj.entry(dev_id.clone()).or_default().push(pfx_id.clone());
        rev.entry(pfx_id).or_default().push(dev_id);
    }

    let mut asn_ids: HashMap<i64, Vec<String>> = HashMap::new();
    for (id, node) in &node_map {
        if node.kind() == "ASN"
            && let Some(asn) = node.ext_asn.filter(|&a| a > 0)
        {
            asn_ids.entry(asn).or_default().push(id.clone());
        }
    }
    for (_dev, pfx) in device_prefix_links {
        let pfx_id = pfx.canonical_id();
        if let Some(asn) = pfx.prefix_asn
            && let Some(targets) = asn_ids.get(&asn)
        {
            for asn_id in targets {
                rev.entry(asn_id.clone()).or_default().push(pfx_id.clone());
            }
        }
    }

    let mut spofs = Vec::new();
    for (id, node) in &node_map {
        if !matches!(
            node.kind(),
            "TransitRouter" | "IXP" | "Facility" | "ASN" | "AnycastPop" | "HopNode" | "Vantage"
        ) {
            continue;
        }
        let targets = reachable_kinds(id, &adj, &node_map, &["SaasTarget"]);
        if targets.len() < min_targets {
            continue;
        }
        let devices = reachable_kinds(id, &rev, &node_map, &["Device"]);
        let port_speed_mbps = node
            .port_speed_mbps
            .filter(|&v| v > 0)
            .or_else(|| min_edge_speed.get(id).copied());
        spofs.push(SharedFateSpof {
            id: id.clone(),
            kind: node.kind().to_string(),
            label: node.label.clone(),
            asn: node.ext_asn.or(node.prefix_asn),
            region: node.region.clone(),
            outage_state: node.outage_state.clone(),
            port_speed_mbps,
            target_count: targets.len(),
            device_count: devices.len(),
            targets,
            devices,
        });
    }

    spofs.sort_by(|a, b| {
        b.target_count
            .cmp(&a.target_count)
            .then_with(|| b.device_count.cmp(&a.device_count))
            .then_with(|| a.id.cmp(&b.id))
    });
    spofs.truncate(limit);
    spofs
}

fn reachable_kinds(
    start: &str,
    graph: &HashMap<String, Vec<String>>,
    nodes: &HashMap<String, RawNode>,
    wanted_kinds: &[&str],
) -> Vec<String> {
    let mut visited = HashSet::from([start.to_string()]);
    let mut queue = VecDeque::from([(start.to_string(), 0usize)]);
    let mut matched = BTreeSet::new();
    while let Some((cur, depth)) = queue.pop_front() {
        if depth >= 8 {
            continue;
        }
        if let Some(nexts) = graph.get(&cur) {
            for next in nexts {
                if visited.insert(next.clone()) {
                    if let Some(node) = nodes.get(next)
                        && wanted_kinds.contains(&node.kind())
                    {
                        matched.insert(next.clone());
                    }
                    queue.push_back((next.clone(), depth + 1));
                }
            }
        }
    }
    matched.into_iter().collect()
}

#[derive(Debug, Deserialize, Default)]
pub(crate) struct RawEdgeWithEnds {
    #[serde(default)]
    pub(crate) uid: String,
    #[serde(default, rename = "topo.port_speed_mbps")]
    pub(crate) port_speed_mbps: Option<i64>,
    #[serde(default, rename = "topo.src")]
    pub(crate) src: Vec<RawNode>,
    #[serde(default, rename = "topo.dst")]
    pub(crate) dst: Vec<RawNode>,
}

#[derive(Debug, Deserialize, Default)]
struct EdgesBlock {
    #[serde(default)]
    edges: Vec<RawEdgeWithEnds>,
}

#[derive(Debug, Deserialize, Default)]
struct SpofPrefixRow {
    #[serde(flatten)]
    node: RawNode,
    #[serde(default, rename = "~iface.prefixes")]
    rev_ifaces: Vec<IfaceDevices>,
}

#[derive(Debug, Deserialize, Default)]
struct SpofPrefixesBlock {
    #[serde(default)]
    prefixes: Vec<SpofPrefixRow>,
}
