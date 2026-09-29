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

use crate::client::CanonicalEdgeRow;
use crate::{CanonicalEdge, CanonicalGraph, TopologyError};

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

pub(crate) async fn graph(client: &DgraphClient) -> Result<CanonicalGraph, TopologyError> {
    let mut txn = client.new_read_only_txn();
    let nodes = scan(&mut txn, &DEVICES, Some).await?;
    let edges = scan(&mut txn, &EDGES, CanonicalEdgeRow::into_edge).await?;
    Ok(CanonicalGraph::new(nodes, edges))
}

pub(crate) async fn edges(client: &DgraphClient) -> Result<Vec<CanonicalEdge>, TopologyError> {
    scan(
        &mut client.new_read_only_txn(),
        &EDGES,
        CanonicalEdgeRow::into_edge,
    )
    .await
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
    convert: fn(T) -> Option<U>,
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
            Err(error) => return Err(TopologyError::Dgraph(error.to_string())),
        };
        if response.aborted()
            || response
                .start_ts()
                .is_none_or(|ts| ts == 0 || ts != txn.start_ts())
        {
            return Err(TopologyError::Dgraph(
                "canonical page lacks a consistent transaction timestamp".into(),
            ));
        }
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
