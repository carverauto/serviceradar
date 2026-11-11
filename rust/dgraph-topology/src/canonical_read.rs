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

//! UID pagination stays inside one read-only transaction, below tonic's receive
//! ceiling. Failed pages never expose a partial canonical graph to the caller.
//! Existing canonical admission is unchanged: relations whose endpoints carry no
//! identity are excluded, while their raw UIDs still advance the page cursor.

use std::collections::HashMap;

use dgraph_client::{DgraphClient, DgraphError, DgraphErrorEnum, ReadOnly, Txn};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::client::{CanonicalEdgeRow, dql_string};
use crate::{CanonicalEdge, CanonicalGraph, TopologyError, TopologyView};

const PAGE_SIZE: usize = 256;
const DEVICES: QueryBlock = QueryBlock {
    name: "nodes",
    kind: "Device",
    filter: "has(device.id)",
    fields: "device.id device.hostname device.ip",
};
const EDGES: QueryBlock = QueryBlock {
    name: "edges",
    kind: "TopologyEdge",
    filter: r#"eq(topo.kind, "CANONICAL_TOPOLOGY") AND NOT eq(topo.stale, true)"#,
    fields: "topo.link_key topo.protocol topo.evidence_class topo.confidence_tier
      topo.flow_pps_ab topo.flow_pps_ba topo.flow_bps_ab topo.flow_bps_ba
      topo.capacity_bps topo.telemetry_eligible topo.if_index_ab topo.if_index_ba
      topo.if_name_ab topo.if_name_ba topo.mutation_id topo.pair_support_rank
      topo.src { device.id } topo.dst { device.id }",
};
const VIEW_EDGES: QueryBlock = QueryBlock {
    name: "edges",
    kind: "TopologyEdge",
    filter: r#"(eq(topo.kind, "CANONICAL_TOPOLOGY") AND NOT eq(topo.stale, true)) OR eq(topo.kind, "ATTACHED_TO") OR eq(topo.kind, "INFERRED_TO") OR eq(topo.kind, "HOSTED_ON")"#,
    fields: "topo.kind topo.stale topo.last_seen topo.link_key topo.protocol topo.evidence_class topo.confidence_tier
      topo.flow_pps_ab topo.flow_pps_ba topo.flow_bps_ab topo.flow_bps_ba
      topo.capacity_bps topo.telemetry_eligible topo.if_index_ab topo.if_index_ba
      topo.if_name_ab topo.if_name_ba topo.mutation_id topo.pair_support_rank
      topo.src { device.id } topo.dst { device.id }",
};

// The canonical rebuild's inputs: current canonical edges and current mapper
// evidence. Endpoints carry only their identity. A row here must not embed
// `device.interfaces`: that repeats a device's whole port list on every edge it
// terminates, so the response grows with edges times ports. The rebuild
// resolves the ports it attributes by key instead (see `interfaces`).
const REBUILD_INPUTS: QueryBlock = QueryBlock {
    name: "edges",
    kind: "TopologyEdge",
    filter: r#"NOT eq(topo.stale, true) AND (eq(topo.kind, "CANONICAL_TOPOLOGY") OR (eq(topo.ingestor, "mapper_topology_v1") AND eq(topo.kind, ["CONNECTS_TO", "LOGICAL_PEER", "HOSTED_ON", "INFERRED_TO", "ATTACHED_TO", "OBSERVED_TO"])))"#,
    fields: "topo.kind topo.protocol topo.evidence_class topo.ingestor topo.confidence_tier
      topo.if_name_ab topo.if_name_ba topo.if_index_ab topo.if_index_ba
      topo.flow_pps_ab topo.flow_pps_ba topo.flow_bps_ab topo.flow_bps_ba
      topo.capacity_bps topo.telemetry_eligible topo.last_seen topo.mutation_id
      topo.agent_id topo.pair_support_rank
      topo.src { device.id } topo.dst { device.id }",
};
const INTERFACES: &str = "interfaces";

pub(crate) async fn graph(client: &DgraphClient) -> Result<CanonicalGraph, TopologyError> {
    let mut txn = client.new_read_only_txn();
    let nodes = scan(&mut txn, &DEVICES, Some).await?;
    let edges = scan(&mut txn, &EDGES, CanonicalEdgeRow::into_edge).await?;
    Ok(CanonicalGraph::new(nodes, edges))
}

pub(crate) async fn view(
    client: &DgraphClient,
    stale_cutoff: &str,
) -> Result<TopologyView, TopologyError> {
    let stale_cutoff = chrono::DateTime::parse_from_rfc3339(stale_cutoff)
        .map_err(|error| TopologyError::Serde(error.to_string()))?;
    let mut txn = client.new_read_only_txn();
    let nodes = scan(&mut txn, &DEVICES, Some).await?;
    let edges = scan(&mut txn, &VIEW_EDGES, |row: CanonicalEdgeRow| {
        row.into_view_edge(stale_cutoff)
    })
    .await?;
    Ok(TopologyView::new(nodes, edges))
}

pub(crate) async fn edges(client: &DgraphClient) -> Result<Vec<CanonicalEdge>, TopologyError> {
    scan(
        &mut client.new_read_only_txn(),
        &EDGES,
        CanonicalEdgeRow::into_edge,
    )
    .await
}

/// Every row the rebuild reads, undecoded and in UID order. Nothing is dropped
/// here: the caller must see a canonical row it cannot decode and refuse to
/// rebuild, not receive a shorter set and prune what is missing from it.
pub(crate) async fn rebuild_inputs(client: &DgraphClient) -> Result<Vec<Value>, TopologyError> {
    scan(
        &mut client.new_read_only_txn(),
        &REBUILD_INPUTS,
        |row: Map<String, Value>| Some(Value::Object(row)),
    )
    .await
}

/// The Interface vertices carrying `keys`, with the id of each owning device,
/// read from one snapshot in chunks of at most [`PAGE_SIZE`] keys. A chunk whose
/// response exceeds the receive ceiling is split and retried; a single key that
/// cannot be read fails the whole lookup.
pub(crate) async fn interfaces(
    client: &DgraphClient,
    keys: &[String],
) -> Result<Vec<Value>, TopologyError> {
    let mut txn = client.new_read_only_txn();
    let mut result = Vec::new();
    let mut pending: Vec<&[String]> = keys.chunks(PAGE_SIZE).rev().collect();
    while let Some(chunk) = pending.pop() {
        let list = chunk
            .iter()
            .map(|key| dql_string(key))
            .collect::<Vec<_>>()
            .join(", ");
        let query = format!(
            "{{ {INTERFACES}(func: eq(iface.key, [{list}])) {{ iface.key iface.name iface.if_index ~device.interfaces {{ device.id }} }} }}"
        );
        let response = match txn.query(query).await {
            Ok(response) => response,
            Err(error) if chunk.len() > 1 && exceeds_receive_limit(&error) => {
                let (head, tail) = chunk.split_at(chunk.len() / 2);
                pending.push(tail);
                pending.push(head);
                continue;
            }
            Err(error) => return Err(TopologyError::from_dgraph(&error)),
        };
        require_snapshot(&response, &txn)?;
        let mut blocks: HashMap<String, Vec<Value>> = serde_json::from_slice(response.json())
            .map_err(|error| TopologyError::Serde(error.to_string()))?;
        result.append(&mut blocks.remove(INTERFACES).ok_or_else(|| {
            TopologyError::Serde(format!("interface lookup is missing {INTERFACES}"))
        })?);
    }
    Ok(result)
}

struct QueryBlock {
    name: &'static str,
    kind: &'static str,
    filter: &'static str,
    fields: &'static str,
}

impl QueryBlock {
    fn query(&self, first: usize, after: u64) -> String {
        let cursor = if after == 0 {
            String::new()
        } else {
            format!(", after: {after:#x}")
        };
        format!(
            "{{ {name}(func: type({kind}), first: {first}{cursor}) @filter({filter}) {{ uid {fields} }} }}",
            name = self.name,
            kind = self.kind,
            filter = self.filter,
            fields = self.fields,
        )
    }
}

#[derive(Deserialize)]
struct PageRow<T> {
    uid: String,
    #[serde(flatten)]
    data: T,
}

async fn scan<T: DeserializeOwned, U>(
    txn: &mut Txn<ReadOnly>,
    block: &QueryBlock,
    convert: impl Fn(T) -> Option<U>,
) -> Result<Vec<U>, TopologyError> {
    let mut result = Vec::new();
    let mut after = 0;
    let mut page_size = PAGE_SIZE;
    loop {
        let response = match txn.query(block.query(page_size, after)).await {
            Ok(response) => response,
            Err(error) if page_size > 1 && exceeds_receive_limit(&error) => {
                // Strings are not bounded in the canonical store. A row count
                // alone cannot guarantee the wire budget; retry the same cursor
                // at a smaller size, retaining any established snapshot.
                page_size /= 2;
                continue;
            }
            Err(error) => return Err(TopologyError::from_dgraph(&error)),
        };
        require_snapshot(&response, txn)?;
        let mut blocks: HashMap<String, Vec<PageRow<T>>> = serde_json::from_slice(response.json())
            .map_err(|error| TopologyError::Serde(error.to_string()))?;
        let rows = blocks.remove(block.name).ok_or_else(|| {
            TopologyError::Serde(format!("canonical page is missing {}", block.name))
        })?;
        let count = rows.len();
        if count > page_size {
            return Err(TopologyError::Serde(
                "canonical page exceeds requested row limit".into(),
            ));
        }
        for row in rows {
            after = next_uid(&row.uid, after)?;
            if let Some(value) = convert(row.data) {
                result.push(value);
            }
        }
        // Use the raw page, not the admitted identities: an incomplete relation
        // does not erase valid relations on subsequent pages.
        if count < page_size {
            return Ok(result);
        }
    }
}

fn require_snapshot(
    response: &dgraph_client::Response,
    txn: &Txn<ReadOnly>,
) -> Result<(), TopologyError> {
    if response.aborted()
        || response
            .start_ts()
            .is_none_or(|ts| ts == 0 || ts != txn.start_ts())
    {
        return Err(TopologyError::Dgraph(
            "canonical page lacks a consistent transaction timestamp".into(),
        ));
    }
    Ok(())
}

fn next_uid(uid: &str, after: u64) -> Result<u64, TopologyError> {
    uid.strip_prefix("0x")
        .filter(|digits| !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .and_then(|digits| u64::from_str_radix(digits, 16).ok())
        .filter(|&next| next > after)
        .ok_or_else(|| {
            TopologyError::Serde("canonical page has an invalid or non-advancing UID".into())
        })
}

fn exceeds_receive_limit(error: &DgraphError) -> bool {
    matches!(
        error.kind(),
        DgraphErrorEnum::Rpc { code: tonic::Code::OutOfRange, message }
            if message.starts_with("Error, decoded message length too large:")
    )
}
