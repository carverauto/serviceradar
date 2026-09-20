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

use dgraph_topology::{CanonicalEdge, EdgeKind, EdgeWrite, link_key};

use crate::CanonicalEdgeRecord;

/// Every record the migrator rebuilds is a canonical-topology edge; the
/// checksum compares this one identity on both stores.
const CANONICAL_KIND: &str = EdgeKind::CanonicalTopology.as_str();

/// Store-independent identity for a canonical edge, in the Dgraph key format.
#[must_use]
pub fn canonical_link_key(source: &str, target: &str, if_ab: &str, if_ba: &str) -> String {
    link_key(CANONICAL_KIND, source, target, if_ab, if_ba)
}

#[derive(Debug, Clone)]
pub struct MapperLinkRow {
    pub local_device_id: String,
    pub neighbor_device_id: String,
    pub protocol: String,
    pub local_if_name: String,
    pub neighbor_if_name: String,
}

#[must_use]
pub fn records_from_mapper_rows(rows: &[MapperLinkRow]) -> Vec<CanonicalEdgeRecord> {
    rows.iter().filter_map(record_from_mapper).collect()
}

#[must_use]
pub fn records_from_canonical_edges(edges: &[CanonicalEdge]) -> Vec<CanonicalEdgeRecord> {
    edges.iter().map(CanonicalEdgeRecord::from).collect()
}

#[must_use]
pub fn edge_writes_from_records(records: &[CanonicalEdgeRecord]) -> Vec<EdgeWrite> {
    records
        .iter()
        .map(|record| {
            EdgeWrite::canonical(
                record.source.clone(),
                record.target.clone(),
                record.protocol.clone(),
                record.evidence_class.clone(),
            )
            .with_interfaces(&record.if_name_ab, 0, &record.if_name_ba, 0)
        })
        .collect()
}

impl From<&CanonicalEdge> for CanonicalEdgeRecord {
    fn from(edge: &CanonicalEdge) -> Self {
        Self {
            link_key: canonical_link_key(
                edge.source(),
                edge.target(),
                edge.local_if_name_ab(),
                edge.local_if_name_ba(),
            ),
            source: edge.source().to_string(),
            target: edge.target().to_string(),
            protocol: edge.protocol().to_string(),
            evidence_class: edge.evidence_class().to_string(),
            if_name_ab: edge.local_if_name_ab().to_string(),
            if_name_ba: edge.local_if_name_ba().to_string(),
        }
    }
}

fn record_from_mapper(row: &MapperLinkRow) -> Option<CanonicalEdgeRecord> {
    let source = canonical_id(&row.local_device_id)?;
    let target = canonical_id(&row.neighbor_device_id)?;
    if source == target {
        return None;
    }
    Some(CanonicalEdgeRecord {
        link_key: canonical_link_key(&source, &target, &row.local_if_name, &row.neighbor_if_name),
        source,
        target,
        protocol: nonempty(row.protocol.clone(), "unknown"),
        evidence_class: "direct".to_string(),
        if_name_ab: row.local_if_name.clone(),
        if_name_ba: row.neighbor_if_name.clone(),
    })
}

fn canonical_id(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.starts_with("sr:") {
        Some(trimmed.to_string())
    } else {
        None
    }
}

fn nonempty(value: String, fallback: &str) -> String {
    if value.trim().is_empty() {
        fallback.to_string()
    } else {
        value
    }
}
