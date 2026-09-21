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

//! Typed JSON mutations and reads. Callers do not concatenate DQL for writes.

use chrono::{SecondsFormat, Utc};
use dgraph_client::{DgraphClient, Mutation};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::downstream::{DownstreamFact, looks_like_cidr, reachable_on_canonical};
use crate::errors::TopologyError;
use crate::types::{
    CanonicalEdge, ChangeWrite, DeviceWrite, EdgeWrite, HopWrite, InterfaceWrite, PrefixWrite,
};

/// Topology operations against one Dgraph client.
#[derive(Clone)]
pub struct TopologyClient {
    client: DgraphClient,
}

impl TopologyClient {
    /// Wrap an already-connected client.
    #[must_use]
    pub fn new(client: DgraphClient) -> Self {
        Self { client }
    }

    /// Connect using a `dgraph://` URL.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError::Connect`] when the cluster is unreachable.
    pub async fn connect(target: &str) -> Result<Self, TopologyError> {
        let client = DgraphClient::connect(target)
            .await
            .map_err(|err| TopologyError::Connect(target.to_string(), err.to_string()))?;
        Ok(Self { client })
    }

    /// The underlying Dgraph client.
    #[must_use]
    pub fn dgraph(&self) -> &DgraphClient {
        &self.client
    }

    /// Upsert a Device on `device.id`.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if the mutation is refused or the value cannot
    /// be placed in DQL.
    pub async fn upsert_device(&self, device: &DeviceWrite) -> Result<(), TopologyError> {
        let id = dql_string(device.id())?;
        let query = format!("{{ q(func: eq(device.id, {id})) {{ v as uid }} }}");
        let mut node = json!({
            "uid": "uid(v)",
            "dgraph.type": "Device",
            "device.id": device.id(),
        });
        if let Some(hostname) = device.hostname() {
            node["device.hostname"] = json!(hostname);
        }
        if let Some(ip) = device.ip() {
            node["device.ip"] = json!(ip);
        }
        if let Some(revision) = device.config_revision_id() {
            node["device.config_revision_id"] = json!(revision);
        }
        if let Some(severity) = device.pkg_worst_severity() {
            node["device.pkg_worst_severity"] = json!(severity);
        }
        if let Some(count) = device.pkg_critical_count() {
            node["device.pkg_critical_count"] = json!(count);
        }
        if let Some(count) = device.pkg_kev_count() {
            node["device.pkg_kev_count"] = json!(count);
        }
        if let Some(flag) = device.pkg_has_unpatched_rce() {
            node["device.pkg_has_unpatched_rce"] = json!(flag);
        }
        if let Some(at) = device.pkg_risk_summary_at() {
            node["device.pkg_risk_summary_at"] = json!(at);
        }
        let _: Value = self
            .upsert(&query, "@if(ge(len(v), 0))", &node, None)
            .await?;
        Ok(())
    }

    /// Upsert an Interface on `iface.key` and attach it to its Device.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_device`], plus [`TopologyError::ConditionSkipped`]
    /// when the owning device is missing.
    pub async fn upsert_interface(&self, iface: &InterfaceWrite) -> Result<(), TopologyError> {
        let device_id = dql_string(iface.device_id())?;
        let key = dql_string(iface.key())?;
        let query = format!(
            "{{
  device(func: eq(device.id, {device_id})) {{ d as uid }}
  iface(func: eq(iface.key, {key})) {{ i as uid }}
}}"
        );
        let mut node = json!({
            "uid": "uid(i)",
            "dgraph.type": "Interface",
            "iface.key": iface.key(),
        });
        if let Some(name) = iface.name() {
            node["iface.name"] = json!(name);
        }
        if let Some(if_index) = iface.if_index() {
            node["iface.if_index"] = json!(if_index);
        }
        let set = json!([
            node,
            {
                "uid": "uid(d)",
                "device.interfaces": [{"uid": "uid(i)"}]
            }
        ]);
        let blocks: NamedUidBlocks = self
            .upsert(&query, "@if(eq(len(d), 1))", &set, None)
            .await?;
        require_block(&blocks.device, "device", iface.device_id())?;
        Ok(())
    }

    /// Upsert a Prefix on `prefix.cidr`.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_device`].
    pub async fn upsert_prefix(&self, prefix: &PrefixWrite) -> Result<(), TopologyError> {
        let cidr = dql_string(prefix.cidr())?;
        let query = format!("{{ q(func: eq(prefix.cidr, {cidr})) {{ v as uid }} }}");
        let node = json!({
            "uid": "uid(v)",
            "dgraph.type": "Prefix",
            "prefix.cidr": prefix.cidr(),
            "prefix.family": prefix.family(),
        });
        let _: Value = self
            .upsert(&query, "@if(ge(len(v), 0))", &node, None)
            .await?;
        Ok(())
    }

    /// Attach an Interface to a Prefix via `iface.prefixes`.
    ///
    /// # Errors
    ///
    /// [`TopologyError::ConditionSkipped`] if either node is missing.
    pub async fn attach_prefix(&self, iface_key: &str, cidr: &str) -> Result<(), TopologyError> {
        let iface_key_q = dql_string(iface_key)?;
        let cidr_q = dql_string(cidr)?;
        let query = format!(
            "{{
  iface(func: eq(iface.key, {iface_key_q})) {{ i as uid }}
  prefix(func: eq(prefix.cidr, {cidr_q})) {{ p as uid }}
}}"
        );
        let set = json!({
            "uid": "uid(i)",
            "iface.prefixes": [{"uid": "uid(p)"}]
        });
        let blocks: NamedUidBlocks = self
            .upsert(&query, "@if(eq(len(i), 1) AND eq(len(p), 1))", &set, None)
            .await?;
        require_block(&blocks.iface, "iface", iface_key)?;
        require_block(&blocks.prefix, "prefix", cidr)?;
        Ok(())
    }

    /// Upsert a Change and `change.affects` edges. No config body is written.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_device`].
    pub async fn upsert_change(&self, change: &ChangeWrite) -> Result<(), TopologyError> {
        let id = dql_string(change.id())?;
        let mut blocks = vec![format!("q(func: eq(change.id, {id})) {{ v as uid }}")];
        let mut affects = Vec::new();
        let mut targets = Vec::new();
        for cidr in change.affects_prefix_cidrs() {
            targets.push(("prefix.cidr", "Prefix", cidr.as_str()));
        }
        for device_id in change.affects_device_ids() {
            targets.push(("device.id", "Device", device_id.as_str()));
        }
        for (index, (predicate, node_type, value)) in targets.into_iter().enumerate() {
            let value_q = dql_string(value)?;
            let var = format!("t{index}");
            blocks.push(format!(
                "affect{index}(func: eq({predicate}, {value_q})) {{ {var} as uid }}"
            ));
            affects.push(json!({
                "uid": format!("uid({var})"),
                "dgraph.type": node_type,
                predicate: value,
            }));
        }
        let query = format!("{{\n  {}\n}}", blocks.join("\n  "));
        let mut node = json!({
            "uid": "uid(v)",
            "dgraph.type": "Change",
            "change.id": change.id(),
            "change.kind": change.kind(),
            "change.status": change.status(),
            "change.source": change.source(),
            "change.affects": affects,
        });
        if let Some(start) = change.window_start() {
            node["change.window_start"] = json!(start);
        }
        if let Some(end) = change.window_end() {
            node["change.window_end"] = json!(end);
        }
        let _: Value = self
            .upsert(&query, "@if(ge(len(v), 0))", &node, None)
            .await?;
        Ok(())
    }

    /// Upsert a HopNode on `hop.ip`.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_device`].
    pub async fn upsert_hop(&self, hop: &HopWrite) -> Result<(), TopologyError> {
        let ip = dql_string(hop.ip())?;
        let query = format!("{{ q(func: eq(hop.ip, {ip})) {{ v as uid }} }}");
        let node = json!({
            "uid": "uid(v)",
            "dgraph.type": "HopNode",
            "hop.ip": hop.ip(),
        });
        let _: Value = self
            .upsert(&query, "@if(ge(len(v), 0))", &node, None)
            .await?;
        Ok(())
    }

    /// Upsert a reified TopologyEdge. Missing endpoints skip `@if` and fail.
    ///
    /// # Errors
    ///
    /// [`TopologyError::ConditionSkipped`] when source or target is missing.
    pub async fn upsert_edge(&self, edge: &EdgeWrite) -> Result<(), TopologyError> {
        let source = dql_string(edge.source())?;
        let target = dql_string(edge.target())?;
        let key = dql_string(&edge.link_key())?;
        let query = format!(
            "{{
  var(func: eq(device.id, {source})) {{ sd as uid }}
  var(func: eq(hop.ip, {source})) {{ sh as uid }}
  var(func: eq(device.id, {target})) {{ dd as uid }}
  var(func: eq(hop.ip, {target})) {{ dh as uid }}
  src(func: uid(sd, sh)) {{ s as uid }}
  dst(func: uid(dd, dh)) {{ d as uid }}
  edge(func: eq(topo.link_key, {key})) {{ e as uid }}
}}"
        );
        let mut node = json!({
            "uid": "uid(e)",
            "dgraph.type": "TopologyEdge",
            "topo.link_key": edge.link_key(),
            "topo.src": [{"uid": "uid(s)"}],
            "topo.dst": [{"uid": "uid(d)"}],
            "topo.kind": edge.kind().as_str(),
            "topo.protocol": edge.protocol(),
            "topo.evidence_class": edge.evidence_class(),
            "topo.ingestor": edge.ingestor(),
            "topo.confidence_tier": edge.confidence_tier(),
            "topo.flow_pps_ab": edge.flow_pps_ab(),
            "topo.flow_pps_ba": edge.flow_pps_ba(),
            "topo.flow_bps_ab": edge.flow_bps_ab(),
            "topo.flow_bps_ba": edge.flow_bps_ba(),
            "topo.capacity_bps": edge.capacity_bps(),
            "topo.telemetry_eligible": edge.telemetry_eligible(),
            "topo.if_index_ab": edge.if_index_ab(),
            "topo.if_index_ba": edge.if_index_ba(),
            "topo.if_name_ab": edge.if_name_ab(),
            "topo.if_name_ba": edge.if_name_ba(),
            "topo.stale": false,
        });
        // Always present: an edge without `topo.last_seen` never matches the
        // prune filter's `lt()` and would outlive every cutoff.
        node["topo.last_seen"] = if edge.last_seen().is_empty() {
            json!(Utc::now().to_rfc3339_opts(SecondsFormat::Micros, true))
        } else {
            json!(edge.last_seen())
        };
        if !edge.mutation_id().is_empty() {
            node["topo.mutation_id"] = json!(edge.mutation_id());
        }
        if let Some(agent_id) = edge.agent_id() {
            node["topo.agent_id"] = json!(agent_id);
        }
        let blocks: NamedUidBlocks = self
            .upsert(&query, "@if(eq(len(s), 1) AND eq(len(d), 1))", &node, None)
            .await?;
        require_block(&blocks.src, "src", edge.source())?;
        require_block(&blocks.dst, "dst", edge.target())?;
        Ok(())
    }

    /// Canonical topology upsert.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_edge`].
    pub async fn upsert_canonical_edge(&self, edge: &EdgeWrite) -> Result<(), TopologyError> {
        self.upsert_edge(edge).await
    }

    /// Mapper evidence edge (`CONNECTS_TO` and friends).
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_edge`].
    pub async fn upsert_mapper_edge(&self, edge: &EdgeWrite) -> Result<(), TopologyError> {
        self.upsert_edge(edge).await
    }

    /// Config-declared edge. Does not overwrite a `direct-physical` backbone;
    /// arbitration stays in the projector. This only persists the evidence edge.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_edge`].
    pub async fn upsert_config_edge(&self, edge: &EdgeWrite) -> Result<(), TopologyError> {
        self.upsert_edge(edge).await
    }

    /// MTR path edge between Device or HopNode identities stored as device.id
    /// or hop.ip. Callers upsert hop vertices first when the IP is unknown.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_edge`].
    pub async fn upsert_mtr_path(&self, edge: &EdgeWrite) -> Result<(), TopologyError> {
        self.upsert_edge(edge).await
    }

    /// Delete edges of the given `kinds` whose `topo.last_seen` is older than
    /// `cutoff` (RFC3339). The caller owns both the cutoff and the kind set,
    /// because each AGE prune statement deletes a different set of relationship
    /// types on its own schedule.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if the query or delete fails.
    pub async fn prune_stale(
        &self,
        cutoff: &str,
        kinds: &[String],
    ) -> Result<usize, TopologyError> {
        if kinds.is_empty() {
            return Ok(0);
        }
        let cutoff_q = dql_string(cutoff)?;
        let mut kind_filters = Vec::with_capacity(kinds.len());
        for kind in kinds {
            let kind_q = dql_string(kind)?;
            kind_filters.push(format!("eq(topo.kind, {kind_q})"));
        }
        let kind_filter = kind_filters.join(" OR ");
        let query = format!(
            "{{
  stale(func: type(TopologyEdge)) @filter(({kind_filter}) AND lt(topo.last_seen, {cutoff_q})) {{
    uid
  }}
}}"
        );
        let parsed: StaleQuery = self.query(&query).await?;
        if parsed.stale.is_empty() {
            return Ok(0);
        }
        let delete: Vec<Value> = parsed
            .stale
            .iter()
            .map(|row| json!({ "uid": row.uid }))
            .collect();
        let mut txn = self.client.new_txn();
        let mutation = Mutation::new().delete_json(
            serde_json::to_vec(&delete).map_err(|err| TopologyError::Serde(err.to_string()))?,
        );
        txn.mutate(mutation)
            .await
            .map_err(|err| TopologyError::Dgraph(err.to_string()))?;
        txn.commit()
            .await
            .map_err(|err| TopologyError::Dgraph(err.to_string()))?;
        Ok(parsed.stale.len())
    }

    /// Upsert the provided canonical edges, then delete canonical edges whose
    /// `topo.link_key` is not in that set.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_edge`].
    pub async fn rebuild_canonical(&self, edges: &[EdgeWrite]) -> Result<(), TopologyError> {
        let mut keep = std::collections::BTreeSet::new();
        for edge in edges {
            self.upsert_canonical_edge(edge).await?;
            keep.insert(edge.link_key());
        }
        let existing = self.query_canonical_edges().await?;
        let stale_keys: Vec<String> = existing
            .iter()
            .filter(|edge| !keep.contains(edge.link_key()))
            .map(|edge| edge.link_key().to_string())
            .collect();
        for key in stale_keys {
            self.delete_edge_by_link_key(&key).await?;
        }
        Ok(())
    }

    /// Read-only DQL. Callers must refuse mutations before invoking this.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if the query fails or the response is not JSON.
    pub async fn query_dql(&self, query: &str) -> Result<Value, TopologyError> {
        self.query(query).await
    }

    /// Edges incident on a device, including non-canonical kinds.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if the query fails or the response is the
    /// wrong shape.
    pub async fn query_neighbourhood(
        &self,
        device_id: &str,
    ) -> Result<Vec<crate::types::NeighbourhoodEdge>, TopologyError> {
        let id = dql_string(device_id)?;
        let query = format!(
            r#"{{
  var(func: eq(device.id, {id})) {{ v as uid }}
  edges(func: type(TopologyEdge)) @filter((uid_in(topo.src, uid(v)) OR uid_in(topo.dst, uid(v))) AND NOT eq(topo.stale, true)) {{
    topo.link_key
    topo.kind
    topo.protocol
    topo.evidence_class
    topo.confidence_tier
    topo.flow_pps_ab
    topo.flow_pps_ba
    topo.flow_bps_ab
    topo.flow_bps_ba
    topo.capacity_bps
    topo.telemetry_eligible
    topo.if_index_ab
    topo.if_index_ba
    topo.if_name_ab
    topo.if_name_ba
    topo.mutation_id
    topo.src {{ device.id hop.ip }}
    topo.dst {{ device.id hop.ip }}
  }}
}}"#
        );
        let parsed: CanonicalQuery = self.query(&query).await?;
        Ok(parsed
            .edges
            .into_iter()
            .filter_map(CanonicalEdgeRow::into_neighbourhood)
            .collect())
    }

    /// Canonical directional edges in the God View shape.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if the query fails or the response is the
    /// wrong shape.
    /// Expand selectors (device ids and CIDRs) then walk canonical topology.
    /// Returns reachable or disjoint — never a postpone/sequence verdict.
    ///
    /// # Errors
    ///
    /// As [`Self::query_canonical_edges`].
    pub async fn downstream_of(
        &self,
        from_ids: &[String],
        to_ids: &[String],
    ) -> Result<DownstreamFact, TopologyError> {
        let from = self.expand_to_devices(from_ids).await?;
        let to = self.expand_to_devices(to_ids).await?;
        let edges = self.query_canonical_edges().await?;
        Ok(reachable_on_canonical(&edges, &from, &to))
    }

    async fn expand_to_devices(
        &self,
        ids: &[String],
    ) -> Result<std::collections::HashSet<String>, TopologyError> {
        let mut devices = std::collections::HashSet::new();
        for id in ids {
            if looks_like_cidr(id) {
                devices.extend(self.devices_for_prefix(id).await?);
            } else if !id.is_empty() {
                devices.insert(id.clone());
            }
        }
        Ok(devices)
    }

    async fn devices_for_prefix(&self, cidr: &str) -> Result<Vec<String>, TopologyError> {
        let cidr_q = dql_string(cidr)?;
        let query = format!(
            "{{
  q(func: eq(prefix.cidr, {cidr_q})) {{
    ~iface.prefixes {{
      ~device.interfaces {{
        device.id
      }}
    }}
  }}
}}"
        );
        let parsed: PrefixExpandQuery = self.query(&query).await?;
        Ok(parsed.device_ids())
    }

    pub async fn query_canonical_edges(&self) -> Result<Vec<CanonicalEdge>, TopologyError> {
        let query = r#"{
  edges(func: type(TopologyEdge)) @filter(eq(topo.kind, "CANONICAL_TOPOLOGY") AND NOT eq(topo.stale, true)) {
    topo.link_key
    topo.protocol
    topo.evidence_class
    topo.confidence_tier
    topo.flow_pps_ab
    topo.flow_pps_ba
    topo.flow_bps_ab
    topo.flow_bps_ba
    topo.capacity_bps
    topo.telemetry_eligible
    topo.if_index_ab
    topo.if_index_ba
    topo.if_name_ab
    topo.if_name_ba
    topo.mutation_id
    topo.src { device.id }
    topo.dst { device.id }
  }
}"#;
        let parsed: CanonicalQuery = self.query(query).await?;
        Ok(parsed
            .edges
            .into_iter()
            .filter_map(CanonicalEdgeRow::into_edge)
            .collect())
    }

    async fn delete_edge_by_link_key(&self, key: &str) -> Result<(), TopologyError> {
        let key_q = dql_string(key)?;
        let query = format!("{{ edge(func: eq(topo.link_key, {key_q})) {{ e as uid }} }}");
        let delete = json!({ "uid": "uid(e)" });
        let _: Value = self
            .upsert(&query, "@if(eq(len(e), 1))", &json!({}), Some(&delete))
            .await?;
        Ok(())
    }

    async fn upsert<T>(
        &self,
        query: &str,
        condition: &str,
        set: &Value,
        delete: Option<&Value>,
    ) -> Result<T, TopologyError>
    where
        T: for<'de> Deserialize<'de>,
    {
        let payload =
            serde_json::to_vec(set).map_err(|err| TopologyError::Serde(err.to_string()))?;
        let mut mutation = Mutation::new().set_json(payload).cond(condition);
        if let Some(delete) = delete {
            mutation = mutation.delete_json(
                serde_json::to_vec(delete).map_err(|err| TopologyError::Serde(err.to_string()))?,
            );
        }
        let mut txn = self.client.new_txn();
        let response = txn
            .upsert(query, vec![mutation], true)
            .await
            .map_err(|err| TopologyError::Dgraph(err.to_string()))?;
        serde_json::from_slice(response.json()).map_err(|err| TopologyError::Serde(err.to_string()))
    }

    async fn query<T>(&self, query: &str) -> Result<T, TopologyError>
    where
        T: for<'de> Deserialize<'de>,
    {
        let response = self
            .client
            .new_read_only_txn()
            .query(query)
            .await
            .map_err(|err| TopologyError::Dgraph(err.to_string()))?;
        serde_json::from_slice(response.json()).map_err(|err| TopologyError::Serde(err.to_string()))
    }
}

#[derive(Debug, Deserialize, Default)]
struct UidRow {
    #[serde(default)]
    uid: String,
}

#[derive(Debug, Deserialize, Default)]
struct NamedUidBlocks {
    #[serde(default)]
    src: Vec<UidRow>,
    #[serde(default)]
    dst: Vec<UidRow>,
    #[serde(default)]
    device: Vec<UidRow>,
    #[serde(default)]
    iface: Vec<UidRow>,
    #[serde(default)]
    prefix: Vec<UidRow>,
    #[serde(default)]
    #[allow(dead_code)]
    q: Vec<UidRow>,
    #[serde(default)]
    #[allow(dead_code)]
    edge: Vec<UidRow>,
}

#[derive(Debug, Deserialize, Default)]
struct StaleQuery {
    #[serde(default)]
    stale: Vec<UidRow>,
}

#[derive(Debug, Deserialize, Default)]
struct EndpointId {
    #[serde(default, rename = "device.id")]
    device_id: String,
    #[serde(default, rename = "hop.ip")]
    hop_ip: String,
}

impl EndpointId {
    /// An MTR path may terminate on a HopNode, which carries `hop.ip` and no
    /// `device.id`. An endpoint with neither is not an identity at all.
    fn id(&self) -> Option<&str> {
        [self.device_id.as_str(), self.hop_ip.as_str()]
            .into_iter()
            .find(|value| !value.is_empty())
    }
}

#[derive(Debug, Deserialize, Default)]
struct CanonicalEdgeRow {
    #[serde(default, rename = "topo.link_key")]
    link_key: String,
    #[serde(default, rename = "topo.kind")]
    kind: String,
    #[serde(default, rename = "topo.protocol")]
    protocol: String,
    #[serde(default, rename = "topo.evidence_class")]
    evidence_class: String,
    #[serde(default, rename = "topo.confidence_tier")]
    confidence_tier: String,
    #[serde(default, rename = "topo.flow_pps_ab")]
    flow_pps_ab: i64,
    #[serde(default, rename = "topo.flow_pps_ba")]
    flow_pps_ba: i64,
    #[serde(default, rename = "topo.flow_bps_ab")]
    flow_bps_ab: i64,
    #[serde(default, rename = "topo.flow_bps_ba")]
    flow_bps_ba: i64,
    #[serde(default, rename = "topo.capacity_bps")]
    capacity_bps: i64,
    #[serde(default, rename = "topo.telemetry_eligible")]
    telemetry_eligible: bool,
    #[serde(default, rename = "topo.if_index_ab")]
    if_index_ab: i32,
    #[serde(default, rename = "topo.if_index_ba")]
    if_index_ba: i32,
    #[serde(default, rename = "topo.if_name_ab")]
    if_name_ab: String,
    #[serde(default, rename = "topo.if_name_ba")]
    if_name_ba: String,
    #[serde(default, rename = "topo.mutation_id")]
    mutation_id: String,
    #[serde(default, rename = "topo.src")]
    src: Vec<EndpointId>,
    #[serde(default, rename = "topo.dst")]
    dst: Vec<EndpointId>,
}

impl CanonicalEdgeRow {
    fn into_edge(self) -> Option<CanonicalEdge> {
        let source = self.src.first().and_then(EndpointId::id)?.to_string();
        let target = self.dst.first().and_then(EndpointId::id)?.to_string();
        Some(CanonicalEdge::new(
            source,
            target,
            self.flow_pps_ab,
            self.flow_pps_ba,
            self.flow_bps_ab,
            self.flow_bps_ba,
            self.capacity_bps,
            self.telemetry_eligible,
            self.protocol,
            self.evidence_class,
            self.confidence_tier,
            self.if_index_ab,
            self.if_name_ab,
            self.if_index_ba,
            self.if_name_ba,
            self.link_key,
            self.mutation_id,
        ))
    }

    fn into_neighbourhood(self) -> Option<crate::types::NeighbourhoodEdge> {
        let kind = if self.kind.is_empty() {
            "CANONICAL_TOPOLOGY".to_string()
        } else {
            self.kind.clone()
        };
        Some(crate::types::NeighbourhoodEdge::new(
            kind,
            self.into_edge()?,
        ))
    }
}

#[derive(Debug, Deserialize, Default)]
struct PrefixExpandQuery {
    #[serde(default)]
    q: Vec<PrefixExpandPrefix>,
}

#[derive(Debug, Deserialize)]
struct PrefixExpandPrefix {
    #[serde(default, rename = "~iface.prefixes")]
    ifaces: Vec<PrefixExpandIface>,
}

#[derive(Debug, Deserialize)]
struct PrefixExpandIface {
    #[serde(default, rename = "~device.interfaces")]
    devices: Vec<PrefixExpandDevice>,
}

#[derive(Debug, Deserialize)]
struct PrefixExpandDevice {
    #[serde(default, rename = "device.id")]
    device_id: Option<String>,
}

impl PrefixExpandQuery {
    fn device_ids(&self) -> Vec<String> {
        self.q
            .iter()
            .flat_map(|prefix| prefix.ifaces.iter())
            .flat_map(|iface| iface.devices.iter())
            .filter_map(|device| device.device_id.clone())
            .collect()
    }
}

#[derive(Debug, Deserialize)]
struct CanonicalQuery {
    #[serde(default)]
    edges: Vec<CanonicalEdgeRow>,
}

fn require_block(rows: &[UidRow], block: &str, key: &str) -> Result<(), TopologyError> {
    if rows.is_empty() {
        return Err(TopologyError::ConditionSkipped(
            block.to_string(),
            key.to_string(),
        ));
    }
    Ok(())
}

/// Reject values that would break DQL string literals.
pub(crate) fn dql_string(value: &str) -> Result<String, TopologyError> {
    if value.contains('"') || value.contains('\n') || value.contains('\\') {
        return Err(TopologyError::InvalidValue(value.to_string()));
    }
    Ok(format!("\"{value}\""))
}

#[cfg(test)]
mod tests {
    use super::{CanonicalEdgeRow, EndpointId};

    fn row(src: serde_json::Value, dst: serde_json::Value) -> CanonicalEdgeRow {
        serde_json::from_value(serde_json::json!({
            "topo.link_key": "MTR_PATH|sr:host01.example.com|192.0.2.10||",
            "topo.kind": "MTR_PATH",
            "topo.src": [src],
            "topo.dst": [dst],
        }))
        .expect("row")
    }

    #[test]
    fn an_mtr_endpoint_may_be_a_hop_node() {
        let edge = row(
            serde_json::json!({ "device.id": "sr:host01.example.com" }),
            serde_json::json!({ "hop.ip": "192.0.2.10" }),
        )
        .into_edge()
        .expect("a hop-terminated MTR edge must read back");

        assert_eq!(edge.source(), "sr:host01.example.com");
        assert_eq!(edge.target(), "192.0.2.10");
    }

    #[test]
    fn an_endpoint_with_no_identity_drops_the_edge() {
        assert!(
            row(
                serde_json::json!({ "device.id": "sr:host01.example.com" }),
                serde_json::json!({}),
            )
            .into_edge()
            .is_none(),
            "an endpoint carrying neither device.id nor hop.ip is not an identity"
        );
    }

    #[test]
    fn device_id_wins_when_an_endpoint_carries_both() {
        let endpoint: EndpointId = serde_json::from_value(serde_json::json!({
            "device.id": "sr:host01.example.com",
            "hop.ip": "192.0.2.10",
        }))
        .expect("endpoint");
        assert_eq!(endpoint.id(), Some("sr:host01.example.com"));
    }
}
