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

use std::collections::BTreeSet;
use std::path::PathBuf;

use dgraph_topology::{DeviceWrite, TopologyClient};

use crate::dump::load_dump;
use crate::postgres::PostgresSource;
use crate::{
    CanonicalEdgeRecord, CanonicalSnapshot, DUMP_PATH_ENV, MigratorError, Mode, compare_snapshots,
    edge_writes_from_records, records_from_canonical_edges, snapshot_from_edges,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RebuildReport {
    pub pre_edge_count: u64,
    pub post_edge_count: u64,
    pub upserted: u64,
}

pub async fn run(mode: Mode) -> Result<(), MigratorError> {
    match mode {
        Mode::Rebuild => {
            let report = rebuild().await?;
            eprintln!(
                "rebuild pre_edges={} post_edges={} upserted={}",
                report.pre_edge_count, report.post_edge_count, report.upserted
            );
            Ok(())
        }
        Mode::Checksum => {
            let report = checksum().await?;
            eprintln!(
                "checksum age_nodes={} age_edges={} dgraph_nodes={} dgraph_edges={} hash={}",
                report.age.node_count,
                report.age.edge_count,
                report.dgraph.node_count,
                report.dgraph.edge_count,
                report.age.content_hash
            );
            Ok(())
        }
        Mode::DumpLoad => {
            let path = std::env::var(DUMP_PATH_ENV)
                .map_err(|_| MigratorError::MissingConfig(DUMP_PATH_ENV.into()))?;
            let dump = load_dump(&PathBuf::from(path))?;
            let report = load_records(&dump.edges).await?;
            eprintln!(
                "dump-load pre_edges={} post_edges={} upserted={} (synthetic fixtures only)",
                report.pre_edge_count, report.post_edge_count, report.upserted
            );
            Ok(())
        }
    }
}

async fn rebuild() -> Result<RebuildReport, MigratorError> {
    let postgres = PostgresSource::connect().await?;
    let records = postgres.evidence_records().await?;
    load_records(&records).await
}

async fn checksum() -> Result<crate::ChecksumReport, MigratorError> {
    let postgres = PostgresSource::connect().await?;
    let age = postgres.relational_snapshot().await?;
    let dgraph = dgraph_snapshot().await?;
    compare_snapshots(&age, &dgraph)
}

async fn load_records(records: &[CanonicalEdgeRecord]) -> Result<RebuildReport, MigratorError> {
    let client = dgraph_client().await?;
    let pre = client
        .query_canonical_edges()
        .await
        .map_err(|err| MigratorError::Dgraph(err.to_string()))?;
    let writes = edge_writes_from_records(records);
    let mut seen = BTreeSet::new();
    for record in records {
        for id in [&record.source, &record.target] {
            if seen.insert(id.clone()) {
                client
                    .upsert_device(&DeviceWrite::new(id.clone()))
                    .await
                    .map_err(|err| MigratorError::Dgraph(err.to_string()))?;
            }
        }
    }
    client
        .rebuild_canonical(&writes)
        .await
        .map_err(|err| MigratorError::Dgraph(err.to_string()))?;
    let post = client
        .query_canonical_edges()
        .await
        .map_err(|err| MigratorError::Dgraph(err.to_string()))?;
    Ok(RebuildReport {
        pre_edge_count: pre.len() as u64,
        post_edge_count: post.len() as u64,
        upserted: writes.len() as u64,
    })
}

async fn dgraph_snapshot() -> Result<CanonicalSnapshot, MigratorError> {
    let client = dgraph_client().await?;
    let edges = client
        .query_canonical_edges()
        .await
        .map_err(|err| MigratorError::Dgraph(err.to_string()))?;
    Ok(snapshot_from_edges(&records_from_canonical_edges(&edges)))
}

async fn dgraph_client() -> Result<TopologyClient, MigratorError> {
    let url = std::env::var("DGRAPH_URL")
        .map_err(|_| MigratorError::MissingConfig("DGRAPH_URL".into()))?;
    TopologyClient::connect(&url)
        .await
        .map_err(|err| MigratorError::Dgraph(err.to_string()))
}
