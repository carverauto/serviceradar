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

//! Chunked, idempotent Dgraph writes and TTL pruning for Horizon external
//! topology snapshots and status patches.

use std::collections::{BTreeSet, HashMap};

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use dgraph_client::Mutation;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::canonical_read::next_uid;
use crate::client::{TopologyClient, dql_string};
use crate::errors::TopologyError;
use crate::schema::{EGRESS_STITCH_INGESTOR, HORIZON_INGESTOR};
use crate::types::{
    ExternalEdgeWrite, ExternalNodeKind, ExternalNodeWrite, ExternalSnapshotWrite,
    ExternalStatusPatch, ExternalUpsertStats,
};

const UPSERT_CHUNK_SIZE: usize = 100;
const AGE_PAGE_SIZE: usize = 4096;
/// Default TTL (15 minutes) used as a fallback against `last_seen` only when
/// `expires_at` is absent on an external node or edge.
pub const DEFAULT_EXTERNAL_TTL_SECS: i64 = 900;

impl TopologyClient {
    /// Upsert a deduplicated Horizon external topology snapshot in bounded
    /// chunks. Repeating the same snapshot is idempotent.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if a Dgraph transaction fails or returns an
    /// invalid response.
    pub async fn upsert_external_topology(
        &self,
        snapshot: &ExternalSnapshotWrite,
    ) -> Result<ExternalUpsertStats, TopologyError> {
        let deduped = snapshot.deduped();
        let mut nodes_upserted = 0usize;
        for chunk in deduped.nodes.chunks(UPSERT_CHUNK_SIZE) {
            nodes_upserted += self.upsert_external_node_chunk(chunk).await?;
        }

        let mut edges_upserted = 0usize;
        let mut edges_skipped = 0usize;
        for chunk in deduped.edges.chunks(UPSERT_CHUNK_SIZE) {
            let (upserted, skipped) = self.upsert_external_edge_chunk(chunk).await?;
            edges_upserted += upserted;
            edges_skipped += skipped;
        }

        Ok(ExternalUpsertStats {
            nodes_upserted,
            edges_upserted,
            edges_skipped,
        })
    }

    /// Apply an incremental status patch (`outage_state`, `rpki_state`,
    /// `rtbh_active`) to an existing external node or prefix.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if the transaction fails.
    pub async fn upsert_external_status(
        &self,
        patch: &ExternalStatusPatch,
    ) -> Result<(), TopologyError> {
        if patch.entity_id.trim().is_empty() {
            return Err(TopologyError::InvalidValue(
                "external status patch entity_id must not be empty".to_string(),
            ));
        }

        let id_q = dql_string(&patch.entity_id);
        let query = format!(
            "{{\n  ext_node(func: eq(ext.id, {id_q})) {{ ext_u as uid }}\n  pfx_node(func: eq(prefix.cidr, {id_q})) {{ pfx_u as uid }}\n}}"
        );

        let mut ext_set = json!({
            "uid": "uid(ext_u)",
            "ext.stale": false,
            "ext.last_seen": patch.last_seen,
        });
        let mut pfx_set = json!({
            "uid": "uid(pfx_u)",
            "prefix.last_seen": patch.last_seen,
        });
        if let Some(outage) = &patch.outage_state {
            ext_set["ext.outage_state"] = json!(outage);
        }
        if let Some(rpki) = &patch.rpki_state {
            ext_set["ext.rpki_state"] = json!(rpki);
            pfx_set["prefix.rpki_state"] = json!(rpki);
        }
        if let Some(rtbh) = patch.rtbh_active {
            ext_set["ext.rtbh_active"] = json!(rtbh);
            pfx_set["prefix.rtbh_active"] = json!(rtbh);
        }
        if let Some(expires_at) = &patch.expires_at {
            ext_set["ext.expires_at"] = json!(expires_at);
            pfx_set["prefix.expires_at"] = json!(expires_at);
        }

        let mutations = vec![
            ext_mutation("@if(eq(len(ext_u), 1))", &ext_set, None)?,
            ext_mutation("@if(eq(len(pfx_u), 1))", &pfx_set, None)?,
        ];
        let _: Value = self.exec_upsert(&query, mutations).await?;
        Ok(())
    }

    /// Delete stale Horizon external edges and orphan external vertices whose
    /// `expires_at` precedes `now_rfc3339`, or (only when `expires_at` is
    /// absent) whose `last_seen` precedes `now_rfc3339 - 900s`. Internal
    /// `Device`, `Interface`, `HopNode`, `CANONICAL_TOPOLOGY`, and `MTR_PATH`
    /// records are never touched.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if `now_rfc3339` is not valid RFC3339 or
    /// Dgraph rejects a page query or mutation.
    pub async fn prune_stale_external(&self, now_rfc3339: &str) -> Result<usize, TopologyError> {
        let (now_iso, fallback_cutoff) =
            derive_external_prune_window(now_rfc3339, DEFAULT_EXTERNAL_TTL_SECS)?;
        let deleted_edges = self
            .prune_stale_external_edges(&now_iso, &fallback_cutoff)
            .await?;
        let deleted_nodes = self
            .prune_orphan_external_nodes(&now_iso, &fallback_cutoff)
            .await?;
        Ok(deleted_edges + deleted_nodes)
    }

    /// Reconcile `egress_stitch_v1` edges by deleting any stored stitch edge
    /// whose `topo.link_key` is not in `keep_link_keys`. When `device_ids` is
    /// non-empty, reconciliation is scoped to outgoing `~topo.src` stitch edges
    /// from those devices; when empty, all `egress_stitch_v1` edges are checked.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if a Dgraph read or delete mutation fails.
    pub async fn reconcile_egress_edges(
        &self,
        device_ids: &[String],
        keep_link_keys: &[String],
    ) -> Result<usize, TopologyError> {
        let keep: BTreeSet<&str> = keep_link_keys.iter().map(String::as_str).collect();
        let stale_uids = if device_ids.is_empty() {
            self.find_stale_egress_uids_global(&keep).await?
        } else {
            self.find_stale_egress_uids_for_devices(device_ids, &keep)
                .await?
        };
        if stale_uids.is_empty() {
            return Ok(0);
        }
        let mut deleted = 0usize;
        for chunk in stale_uids.chunks(UPSERT_CHUNK_SIZE) {
            let deletes: Vec<Value> = chunk.iter().map(|uid| json!({ "uid": uid })).collect();
            let payload = serde_json::to_vec(&deletes)
                .map_err(|err| TopologyError::Serde(err.to_string()))?;
            let mutation = Mutation::new().delete_json(payload);
            let mut txn = self.dgraph().new_txn();
            txn.upsert("", vec![mutation], true)
                .await
                .map_err(|err| TopologyError::from_dgraph(&err))?;
            deleted += chunk.len();
        }
        Ok(deleted)
    }

    async fn find_stale_egress_uids_global(
        &self,
        keep: &BTreeSet<&str>,
    ) -> Result<Vec<String>, TopologyError> {
        let ingestor_q = dql_string(EGRESS_STITCH_INGESTOR);
        let mut after = 0u64;
        let mut stale = Vec::new();
        let mut txn = self.dgraph().new_read_only_txn();
        loop {
            let cursor = if after == 0 {
                String::new()
            } else {
                format!(", after: {after:#x}")
            };
            let query = format!(
                "{{\n  edges(func: type(TopologyEdge), first: {AGE_PAGE_SIZE}{cursor}) \
                 @filter(eq(topo.ingestor, {ingestor_q})) {{\n    uid\n    topo.link_key\n  }}\n}}"
            );
            let resp = txn
                .query(&query)
                .await
                .map_err(|err| TopologyError::from_dgraph(&err))?;
            let page: EgressEdgesBlock = serde_json::from_slice(resp.json())
                .map_err(|err| TopologyError::Serde(err.to_string()))?;
            let count = page.edges.len();
            for row in page.edges {
                after = next_uid(&row.uid, after)?;
                let keep_it = row
                    .link_key
                    .as_deref()
                    .is_some_and(|key| keep.contains(key));
                if !keep_it && !row.uid.is_empty() {
                    stale.push(row.uid);
                }
            }
            if count < AGE_PAGE_SIZE {
                return Ok(stale);
            }
        }
    }

    async fn find_stale_egress_uids_for_devices(
        &self,
        device_ids: &[String],
        keep: &BTreeSet<&str>,
    ) -> Result<Vec<String>, TopologyError> {
        let ingestor_q = dql_string(EGRESS_STITCH_INGESTOR);
        let mut stale = BTreeSet::new();
        let mut txn = self.dgraph().new_read_only_txn();
        for chunk in device_ids.chunks(50) {
            let mut query = String::from("{\n");
            for (idx, device_id) in chunk.iter().enumerate() {
                let id_q = dql_string(device_id);
                query.push_str(&format!(
                    "  d{idx}(func: eq(device.id, {id_q})) {{ ~topo.src @filter(eq(topo.ingestor, {ingestor_q})) {{ uid topo.link_key }} }}\n"
                ));
            }
            query.push('}');
            let resp = txn
                .query(&query)
                .await
                .map_err(|err| TopologyError::from_dgraph(&err))?;
            let map: HashMap<String, Vec<DeviceEgressRow>> = serde_json::from_slice(resp.json())
                .map_err(|err| TopologyError::Serde(err.to_string()))?;
            for dev in map.into_values().flatten() {
                for edge in dev.out_edges {
                    let keep_it = edge
                        .link_key
                        .as_deref()
                        .is_some_and(|key| keep.contains(key));
                    if !keep_it && !edge.uid.is_empty() {
                        stale.insert(edge.uid);
                    }
                }
            }
        }
        Ok(stale.into_iter().collect())
    }

    async fn upsert_external_node_chunk(
        &self,
        nodes: &[ExternalNodeWrite],
    ) -> Result<usize, TopologyError> {
        if nodes.is_empty() {
            return Ok(0);
        }
        let mut query = String::from("{\n");
        let mut mutations = Vec::with_capacity(nodes.len());
        for (idx, node) in nodes.iter().enumerate() {
            let id_q = dql_string(&node.id);
            let pred = if node.kind == ExternalNodeKind::Prefix {
                "prefix.cidr"
            } else {
                "ext.id"
            };
            query.push_str(&format!(
                "  n{idx}(func: eq({pred}, {id_q})) {{ u{idx} as uid }}\n"
            ));
            let payload = external_node_json(node, &format!("uid(u{idx})"));
            mutations.push(ext_mutation(
                &format!("@if(ge(len(u{idx}), 0))"),
                &payload,
                None,
            )?);
        }
        query.push('}');
        let _: Value = self.exec_upsert(&query, mutations).await?;
        Ok(nodes.len())
    }

    async fn upsert_external_edge_chunk(
        &self,
        edges: &[ExternalEdgeWrite],
    ) -> Result<(usize, usize), TopologyError> {
        if edges.is_empty() {
            return Ok((0, 0));
        }
        let mut query = String::from("{\n");
        let mut mutations = Vec::with_capacity(edges.len());
        for (idx, edge) in edges.iter().enumerate() {
            let src_q = dql_string(&edge.src_id);
            let dst_q = dql_string(&edge.dst_id);
            let key_q = dql_string(&edge.link_key());
            query.push_str(&format!(
                "  var(func: eq(device.id, {src_q})) {{ sd{idx} as uid }}
  var(func: eq(hop.ip, {src_q})) {{ sh{idx} as uid }}
  var(func: eq(prefix.cidr, {src_q})) {{ sp{idx} as uid }}
  var(func: eq(ext.id, {src_q})) {{ se{idx} as uid }}
  var(func: eq(device.id, {dst_q})) {{ dd{idx} as uid }}
  var(func: eq(hop.ip, {dst_q})) {{ dh{idx} as uid }}
  var(func: eq(prefix.cidr, {dst_q})) {{ dp{idx} as uid }}
  var(func: eq(ext.id, {dst_q})) {{ de{idx} as uid }}
  src{idx}(func: uid(sd{idx}, sh{idx}, sp{idx}, se{idx})) {{ s{idx} as uid }}
  dst{idx}(func: uid(dd{idx}, dh{idx}, dp{idx}, de{idx})) {{ d{idx} as uid }}
  edge{idx}(func: eq(topo.link_key, {key_q})) {{ e{idx} as uid }}\n"
            ));
            let cond = format!("@if(eq(len(s{idx}), 1) AND eq(len(d{idx}), 1))");
            let payload = external_edge_json(edge, idx);
            mutations.push(ext_mutation(&cond, &payload, None)?);
        }
        query.push('}');

        let blocks: HashMap<String, Vec<UidOnly>> = self.exec_upsert(&query, mutations).await?;
        let mut upserted = 0usize;
        let mut skipped = 0usize;
        for idx in 0..edges.len() {
            let src_len = blocks.get(&format!("src{idx}")).map_or(0, Vec::len);
            let dst_len = blocks.get(&format!("dst{idx}")).map_or(0, Vec::len);
            if src_len == 1 && dst_len == 1 {
                upserted += 1;
            } else {
                skipped += 1;
            }
        }
        Ok((upserted, skipped))
    }

    async fn prune_stale_external_edges(
        &self,
        now_rfc3339: &str,
        fallback_cutoff: &str,
    ) -> Result<usize, TopologyError> {
        let delete = json!({ "uid": "uid(aged)" });
        let mut after = 0u64;
        let mut deleted = 0usize;
        loop {
            let query = build_prune_stale_external_edges_query(
                now_rfc3339,
                fallback_cutoff,
                AGE_PAGE_SIZE,
                after,
            );
            let page: StaleRows = self
                .exec_upsert(
                    &query,
                    vec![ext_mutation(
                        "@if(gt(len(aged), 0))",
                        &json!({}),
                        Some(&delete),
                    )?],
                )
                .await?;
            for row in &page.stale {
                after = next_uid(&row.uid, after)?;
            }
            deleted += page.stale.len();
            if page.stale.len() < AGE_PAGE_SIZE {
                return Ok(deleted);
            }
        }
    }

    async fn prune_orphan_external_nodes(
        &self,
        now_rfc3339: &str,
        fallback_cutoff: &str,
    ) -> Result<usize, TopologyError> {
        let delete = json!({ "uid": "uid(aged)" });
        let mut after = 0u64;
        let mut deleted = 0usize;
        loop {
            let query = build_prune_orphan_external_nodes_query(
                now_rfc3339,
                fallback_cutoff,
                AGE_PAGE_SIZE,
                after,
            );
            let page: StaleRows = self
                .exec_upsert(
                    &query,
                    vec![ext_mutation(
                        "@if(gt(len(aged), 0))",
                        &json!({}),
                        Some(&delete),
                    )?],
                )
                .await?;
            for row in &page.stale {
                after = next_uid(&row.uid, after)?;
            }
            deleted += page.stale.len();
            if page.stale.len() < AGE_PAGE_SIZE {
                return Ok(deleted);
            }
        }
    }

    async fn exec_upsert<T>(
        &self,
        query: &str,
        mutations: Vec<Mutation>,
    ) -> Result<T, TopologyError>
    where
        T: for<'de> Deserialize<'de>,
    {
        let mut txn = self.dgraph().new_txn();
        let response = txn
            .upsert(query, mutations, true)
            .await
            .map_err(|err| TopologyError::from_dgraph(&err))?;
        serde_json::from_slice(response.json()).map_err(|err| TopologyError::Serde(err.to_string()))
    }
}

#[derive(Debug, Deserialize)]
struct UidOnly {
    #[allow(dead_code)]
    uid: String,
}

#[derive(Debug, Deserialize, Default)]
struct StaleRows {
    #[serde(default)]
    stale: Vec<UidOnly>,
}

#[derive(Debug, Deserialize, Default)]
struct EgressEdgeRow {
    #[serde(default)]
    uid: String,
    #[serde(default, rename = "topo.link_key")]
    link_key: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
struct EgressEdgesBlock {
    #[serde(default)]
    edges: Vec<EgressEdgeRow>,
}

#[derive(Debug, Deserialize, Default)]
struct DeviceEgressRow {
    #[serde(default, rename = "~topo.src")]
    out_edges: Vec<EgressEdgeRow>,
}

fn ext_mutation(
    condition: &str,
    set: &Value,
    delete: Option<&Value>,
) -> Result<Mutation, TopologyError> {
    let payload = serde_json::to_vec(set).map_err(|err| TopologyError::Serde(err.to_string()))?;
    let mut mutation = Mutation::new().set_json(payload).cond(condition);
    if let Some(delete) = delete {
        let del =
            serde_json::to_vec(delete).map_err(|err| TopologyError::Serde(err.to_string()))?;
        mutation = mutation.delete_json(del);
    }
    Ok(mutation)
}

fn external_node_json(node: &ExternalNodeWrite, uid: &str) -> Value {
    if node.kind == ExternalNodeKind::Prefix {
        let family = if node.id.contains(':') {
            "ipv6"
        } else {
            "ipv4"
        };
        let mut obj = json!({
            "uid": uid,
            "dgraph.type": "Prefix",
            "prefix.cidr": node.id,
            "prefix.family": family,
            "prefix.last_seen": node.last_seen,
        });
        set_opt(&mut obj, "prefix.asn", node.asn);
        set_opt(&mut obj, "prefix.rpki_state", node.rpki_state.as_deref());
        set_opt(&mut obj, "prefix.rtbh_active", node.rtbh_active);
        set_opt(&mut obj, "prefix.max_length", node.max_length);
        set_opt(&mut obj, "prefix.irr_status", node.irr_status.as_deref());
        set_opt(&mut obj, "prefix.expires_at", node.expires_at.as_deref());
        return obj;
    }

    let ingestor = node
        .ingestor
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(HORIZON_INGESTOR);

    let mut obj = json!({
        "uid": uid,
        "dgraph.type": node.kind.as_str(),
        "ext.id": node.id,
        "ext.kind": node.kind.as_str(),
        "ext.ingestor": ingestor,
        "ext.stale": false,
        "ext.last_seen": node.last_seen,
    });
    set_opt(&mut obj, "ext.asn", node.asn);
    set_opt(&mut obj, "ext.label", node.label.as_deref());
    set_opt(&mut obj, "ext.region", node.region.as_deref());
    set_opt(&mut obj, "ext.ip", node.ip.as_deref());
    set_opt(&mut obj, "ext.rpki_state", node.rpki_state.as_deref());
    set_opt(&mut obj, "ext.rtbh_active", node.rtbh_active);
    set_opt(&mut obj, "ext.metro", node.metro.as_deref());
    set_opt(&mut obj, "ext.iata", node.iata.as_deref());
    set_opt(&mut obj, "ext.country_code", node.country_code.as_deref());
    set_opt(&mut obj, "ext.outage_state", node.outage_state.as_deref());
    set_opt(
        &mut obj,
        "ext.port_speed_mbps",
        node.port_speed_mbps.filter(|&v| v > 0),
    );
    set_opt(&mut obj, "ext.expires_at", node.expires_at.as_deref());
    obj
}

fn external_edge_json(edge: &ExternalEdgeWrite, idx: usize) -> Value {
    let ingestor = edge
        .ingestor
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(HORIZON_INGESTOR);
    let protocol = if ingestor == EGRESS_STITCH_INGESTOR {
        "egress"
    } else {
        "horizon"
    };
    let evidence_class = if ingestor == EGRESS_STITCH_INGESTOR {
        edge.egress_source
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map_or_else(|| "egress".to_string(), |s| format!("egress-{s}"))
    } else {
        "external".to_string()
    };

    let mut obj = json!({
        "uid": format!("uid(e{idx})"),
        "dgraph.type": "TopologyEdge",
        "topo.link_key": edge.link_key(),
        "topo.src": [{"uid": format!("uid(s{idx})")}],
        "topo.dst": [{"uid": format!("uid(d{idx})")}],
        "topo.kind": edge.kind.as_str(),
        "topo.protocol": protocol,
        "topo.evidence_class": evidence_class,
        "topo.ingestor": ingestor,
        "topo.confidence_tier": "observed",
        "topo.stale": false,
        "topo.last_seen": edge.last_seen,
    });
    set_opt(&mut obj, "topo.border_asn", edge.border_asn);
    set_opt(
        &mut obj,
        "topo.as_boundary_confidence",
        edge.as_boundary_confidence,
    );
    set_opt(&mut obj, "topo.avg_rtt_us", edge.avg_rtt_us);
    set_opt(&mut obj, "topo.loss_pct", edge.loss_pct);
    set_opt(
        &mut obj,
        "topo.port_speed_mbps",
        edge.port_speed_mbps.filter(|&v| v > 0),
    );
    set_opt(
        &mut obj,
        "topo.if_name_ab",
        edge.if_name
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty()),
    );
    set_opt(&mut obj, "topo.if_index_ab", edge.if_index);
    set_opt(
        &mut obj,
        "topo.egress_source",
        edge.egress_source
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty()),
    );
    set_opt(&mut obj, "topo.ttl_secs", edge.ttl_secs);
    set_opt(&mut obj, "topo.expires_at", edge.expires_at.as_deref());
    obj
}

fn set_opt<T: serde::Serialize>(obj: &mut Value, key: &str, val: Option<T>) {
    if let Some(value) = val {
        obj[key] = json!(value);
    }
}

/// Derive `(now_rfc3339, fallback_cutoff_rfc3339)` for external topology TTL
/// pruning. `now_rfc3339` is compared against `expires_at`; `fallback_cutoff`
/// (`now - default_ttl_secs`) is compared against `last_seen` only when
/// `expires_at` is absent.
///
/// # Errors
///
/// Returns [`TopologyError::InvalidValue`] if `now_rfc3339` is not valid RFC3339.
pub fn derive_external_prune_window(
    now_rfc3339: &str,
    default_ttl_secs: i64,
) -> Result<(String, String), TopologyError> {
    let parsed = DateTime::parse_from_rfc3339(now_rfc3339.trim()).map_err(|err| {
        TopologyError::InvalidValue(format!("prune timestamp must be RFC3339: {err}"))
    })?;
    let now_utc = parsed.with_timezone(&Utc);
    let fallback_utc = now_utc - Duration::seconds(default_ttl_secs.max(1));
    Ok((
        now_utc.to_rfc3339_opts(SecondsFormat::AutoSi, true),
        fallback_utc.to_rfc3339_opts(SecondsFormat::AutoSi, true),
    ))
}

/// Build the paged DQL query selecting stale external `TopologyEdge` UIDs.
#[must_use]
pub fn build_prune_stale_external_edges_query(
    now_rfc3339: &str,
    fallback_cutoff_rfc3339: &str,
    page_size: usize,
    after: u64,
) -> String {
    let now_q = dql_string(now_rfc3339);
    let fallback_q = dql_string(fallback_cutoff_rfc3339);
    let ingestor_q = dql_string(HORIZON_INGESTOR);
    let cursor = if after == 0 {
        String::new()
    } else {
        format!(", after: {after:#x}")
    };
    format!(
        "{{\n  stale(func: type(TopologyEdge), first: {page_size}{cursor}) @filter(eq(topo.ingestor, {ingestor_q}) AND ((has(topo.expires_at) AND lt(topo.expires_at, {now_q})) OR (NOT has(topo.expires_at) AND lt(topo.last_seen, {fallback_q})))) {{\n    aged as uid\n  }}\n}}"
    )
}

/// Build the paged DQL query selecting stale orphan external vertex UIDs.
#[must_use]
pub fn build_prune_orphan_external_nodes_query(
    now_rfc3339: &str,
    fallback_cutoff_rfc3339: &str,
    page_size: usize,
    after: u64,
) -> String {
    let now_q = dql_string(now_rfc3339);
    let fallback_q = dql_string(fallback_cutoff_rfc3339);
    let ingestor_q = dql_string(HORIZON_INGESTOR);
    let cursor = if after == 0 {
        String::new()
    } else {
        format!(", after: {after:#x}")
    };
    format!(
        "{{\n  stale(func: has(ext.id), first: {page_size}{cursor}) @filter(eq(ext.ingestor, {ingestor_q}) AND ((has(ext.expires_at) AND lt(ext.expires_at, {now_q})) OR (NOT has(ext.expires_at) AND lt(ext.last_seen, {fallback_q}))) AND eq(count(~topo.src), 0) AND eq(count(~topo.dst), 0)) {{\n    aged as uid\n  }}\n}}"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prune_window_and_queries_separate_expires_at_from_fallback_last_seen() {
        let (now, fallback) =
            derive_external_prune_window("2026-11-25T00:16:00Z", DEFAULT_EXTERNAL_TTL_SECS)
                .expect("valid rfc3339");
        assert_eq!(now, "2026-11-25T00:16:00Z");
        assert_eq!(fallback, "2026-11-25T00:01:00Z");

        let edge_q = build_prune_stale_external_edges_query(&now, &fallback, 4096, 0);
        assert!(edge_q.contains(
            "((has(topo.expires_at) AND lt(topo.expires_at, \"2026-11-25T00:16:00Z\")) OR (NOT has(topo.expires_at) AND lt(topo.last_seen, \"2026-11-25T00:01:00Z\")))"
        ));

        let node_q = build_prune_orphan_external_nodes_query(&now, &fallback, 4096, 0x10);
        assert!(node_q.contains("after: 0x10"));
        assert!(node_q.contains(
            "((has(ext.expires_at) AND lt(ext.expires_at, \"2026-11-25T00:16:00Z\")) OR (NOT has(ext.expires_at) AND lt(ext.last_seen, \"2026-11-25T00:01:00Z\")))"
        ));
    }

    #[test]
    fn ttl_semantics_expire_short_ttl_at_60s_and_preserve_6h_ttl_at_16m() {
        let is_stale =
            |expires_at: Option<&str>, last_seen: &str, now: &str, fallback: &str| match expires_at
            {
                Some(exp) => exp < now,
                None => last_seen < fallback,
            };

        let last_seen = "2026-11-25T00:00:00Z";
        let short_exp = "2026-11-25T00:01:00Z";
        let long_exp = "2026-11-25T06:00:00Z";

        let (now_61s, fb_61s) =
            derive_external_prune_window("2026-11-25T00:01:01Z", DEFAULT_EXTERNAL_TTL_SECS)
                .expect("valid");
        assert!(is_stale(Some(short_exp), last_seen, &now_61s, &fb_61s));
        assert!(!is_stale(Some(long_exp), last_seen, &now_61s, &fb_61s));

        let (now_16m, fb_16m) =
            derive_external_prune_window("2026-11-25T00:16:00Z", DEFAULT_EXTERNAL_TTL_SECS)
                .expect("valid");
        assert!(last_seen < fb_16m.as_str());
        assert!(!is_stale(Some(long_exp), last_seen, &now_16m, &fb_16m));
        assert!(is_stale(None, last_seen, &now_16m, &fb_16m));
    }
}
