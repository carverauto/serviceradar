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

//! ServiceRadar topology graph on Dgraph.
//!
//! Predicates are namespaced (`device.*`, `iface.*`, `hop.*`, `collector.*`,
//! `topo.*`, `prefix.*`, `change.*`) so this schema can share a cluster with
//! other graphs. Property-rich edges are reified as `TopologyEdge` nodes.
//! Schema apply/verify/remove goes through `dgraph-migrate`; this crate owns
//! the schema string and the typed mutations.

mod canonical_read;
mod client;
mod downstream;
mod dql_rows;
mod errors;
mod external_reads;
mod external_rows;
mod external_spof;
mod external_writes;
mod reads;
mod schema;
mod types;

#[cfg(all(test, feature = "integration-tests"))]
mod cutover_tests;

pub use crate::client::TopologyClient;
pub use crate::downstream::{DownstreamFact, looks_like_cidr, reachable_on_canonical};
pub use crate::dql_rows::wrap_dql_value;
pub use crate::errors::{TopologyError, TopologyErrorEnum};
pub use crate::external_writes::{
    DEFAULT_EXTERNAL_TTL_SECS, build_prune_orphan_external_nodes_query,
    build_prune_stale_external_edges_query, derive_external_prune_window,
};
pub use crate::reads::{MAX_MTR_PATHS, MtrPath};
pub use crate::schema::{
    HORIZON_INGESTOR, PRED_CHANGE_ID, PRED_DEVICE_ID, PRED_EXT_ID, PRED_LINK_KEY,
    PRED_PREFIX_CIDR, PREDICATES, SCHEMA, TYPES, schema_spec,
};
pub use crate::types::{
    BlastRadiusResult, CanonicalDevice, CanonicalEdge, CanonicalGraph, ChangeWrite,
    CustomerConeResult, DeviceWrite, EdgeKind, EdgeWrite, ExternalEdgeKind, ExternalEdgeRef,
    ExternalEdgeWrite, ExternalNodeKind, ExternalNodeRef, ExternalNodeWrite, ExternalSnapshotWrite,
    ExternalStatusPatch, ExternalUpsertStats, HopWrite, InterfaceWrite, MtrMetrics,
    MultiHopTraceResult, NeighbourhoodEdge, PrefixWrite, SharedFateSpof, TopologyView,
    clamp_max_hops, clamp_query_limit, link_key,
};
