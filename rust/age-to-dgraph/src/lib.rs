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

//! AGE-to-Dgraph topology migrator.
//!
//! Rebuild-from-evidence is the default and the operator-safe recovery path.
//! Checksum compares AGE `platform_graph` to Dgraph and must fail the Job on
//! divergence. Dump-and-load is a lab bootstrap only; live dumps never enter
//! the repository.

mod dump;
mod evidence;
mod postgres;
mod run;
mod tls;

use sha2::{Digest, Sha256};
use thiserror::Error;

pub use dump::{DumpFile, load_dump, parse_dump};
pub use evidence::{
    MapperLinkRow, canonical_link_key, edge_writes_from_records, records_from_canonical_edges,
    records_from_mapper_rows,
};
pub use run::{RebuildReport, run};

pub const MODE_ENV: &str = "AGE_TO_DGRAPH_MODE";
pub const ALLOW_LAB_DUMP_ENV: &str = "AGE_TO_DGRAPH_ALLOW_LAB_DUMP";
pub const DUMP_PATH_ENV: &str = "AGE_TO_DGRAPH_DUMP_PATH";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Rebuild,
    Checksum,
    DumpLoad,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonicalSnapshot {
    pub node_count: u64,
    pub edge_count: u64,
    pub content_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChecksumReport {
    pub age: CanonicalSnapshot,
    pub dgraph: CanonicalSnapshot,
}

#[derive(Debug, Error)]
pub enum MigratorError {
    #[error("unknown mode '{0}'; expected rebuild, checksum, or dump-load")]
    UnknownMode(String),
    #[error("dump-load is lab-only; set {ALLOW_LAB_DUMP_ENV}=1 and never commit live dumps")]
    DumpLoadRefused,
    #[error("checksum mismatch: {0}")]
    ChecksumMismatch(String),
    #[error("missing {0}")]
    MissingConfig(String),
    #[error("{0}")]
    Postgres(String),
    #[error("{0}")]
    Dgraph(String),
    #[error("{0}")]
    Io(String),
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CanonicalEdgeRecord {
    pub link_key: String,
    pub source: String,
    pub target: String,
    pub protocol: String,
    pub evidence_class: String,
    pub if_name_ab: String,
    pub if_name_ba: String,
}

impl Mode {
    pub fn from_env() -> Result<Self, MigratorError> {
        Self::parse(std::env::var(MODE_ENV).ok().as_deref())
    }

    /// Parse a mode. Empty / unset is rebuild (the Job default).
    pub fn parse(raw: Option<&str>) -> Result<Self, MigratorError> {
        match raw.map(str::trim).filter(|value| !value.is_empty()) {
            None => Ok(Self::Rebuild),
            Some(value) if value.eq_ignore_ascii_case("rebuild") => Ok(Self::Rebuild),
            Some(value) if value.eq_ignore_ascii_case("checksum") => Ok(Self::Checksum),
            Some(value) if value.eq_ignore_ascii_case("dump-load") => Ok(Self::DumpLoad),
            Some(value) if value.eq_ignore_ascii_case("dumpload") => Ok(Self::DumpLoad),
            Some(value) => Err(MigratorError::UnknownMode(value.to_string())),
        }
    }

    pub fn require_lab_dump_allowed() -> Result<(), MigratorError> {
        match std::env::var(ALLOW_LAB_DUMP_ENV) {
            Ok(value) if value == "1" || value.eq_ignore_ascii_case("true") => Ok(()),
            _ => Err(MigratorError::DumpLoadRefused),
        }
    }
}

/// One record per `topo.link_key`, which is the identity Dgraph stores.
///
/// Relational evidence is a multiset on a wider key than Dgraph's: two mapper
/// rows for one link discovered by both LLDP and CDP differ only in `protocol`,
/// which is not part of `link_key`, so the rebuild upserts them onto a single
/// node. Counting or hashing them separately would compare a multiset against
/// the set Dgraph actually holds and fail the checksum every time.
///
/// The winner is the first record in sorted order, so it does not depend on the
/// order the database returned rows in.
#[must_use]
pub fn dedupe_by_link_key(records: &[CanonicalEdgeRecord]) -> Vec<CanonicalEdgeRecord> {
    let mut sorted: Vec<&CanonicalEdgeRecord> = records.iter().collect();
    sorted.sort_by_key(|record| hash_line(record));

    let mut seen = std::collections::BTreeSet::new();
    sorted
        .into_iter()
        .filter(|record| seen.insert(record.link_key.clone()))
        .cloned()
        .collect()
}

fn hash_line(edge: &CanonicalEdgeRecord) -> String {
    format!(
        "{}\t{}\t{}\t{}\t{}\t{}\t{}",
        edge.link_key,
        edge.source,
        edge.target,
        edge.protocol,
        edge.evidence_class,
        edge.if_name_ab,
        edge.if_name_ba
    )
}

/// Stable content hash of canonical edges. Order-independent.
#[must_use]
pub fn hash_canonical_edges(edges: &[CanonicalEdgeRecord]) -> String {
    let mut lines: Vec<String> = edges.iter().map(hash_line).collect();
    lines.sort();
    let mut hasher = Sha256::new();
    for line in lines {
        hasher.update(line.as_bytes());
        hasher.update(b"\n");
    }
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Devices that appear as an endpoint of a canonical edge. Counting the whole
/// `:Device` vertex set would compare AGE's inventory against the endpoint-only
/// node set the Dgraph rebuild creates, which can never match.
#[must_use]
pub fn node_count_from_edges(edges: &[CanonicalEdgeRecord]) -> u64 {
    let mut ids = std::collections::BTreeSet::new();
    for edge in edges {
        ids.insert(edge.source.as_str());
        ids.insert(edge.target.as_str());
    }
    ids.len() as u64
}

#[must_use]
pub fn snapshot_from_edges(edges: &[CanonicalEdgeRecord]) -> CanonicalSnapshot {
    CanonicalSnapshot {
        node_count: node_count_from_edges(edges),
        edge_count: edges.len() as u64,
        content_hash: hash_canonical_edges(edges),
    }
}

/// Exact match on node count, canonical-edge count, and content hash.
pub fn compare_snapshots(
    age: &CanonicalSnapshot,
    dgraph: &CanonicalSnapshot,
) -> Result<ChecksumReport, MigratorError> {
    if age == dgraph {
        return Ok(ChecksumReport {
            age: age.clone(),
            dgraph: dgraph.clone(),
        });
    }

    let mut reasons = Vec::new();
    if age.node_count != dgraph.node_count {
        reasons.push(format!(
            "node_count age={} dgraph={}",
            age.node_count, dgraph.node_count
        ));
    }
    if age.edge_count != dgraph.edge_count {
        reasons.push(format!(
            "edge_count age={} dgraph={}",
            age.edge_count, dgraph.edge_count
        ));
    }
    if age.content_hash != dgraph.content_hash {
        reasons.push(format!(
            "content_hash age={} dgraph={}",
            age.content_hash, dgraph.content_hash
        ));
    }
    Err(MigratorError::ChecksumMismatch(reasons.join("; ")))
}
