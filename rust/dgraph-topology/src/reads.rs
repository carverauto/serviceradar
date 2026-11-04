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

//! Typed reads for the device neighbourhood (SRQL `in:device_graph`) and the
//! MTR path overlays.

use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::client::{TopologyClient, dql_string};
use crate::errors::TopologyError;

/// Upper bound on MTR path edges one overlay read returns.
pub const MAX_MTR_PATHS: usize = 1_000;

/// Prefix of the identity an MTR hop without a Device carries in overlays.
const MTR_HOP_ID_PREFIX: &str = "mtr:";

const INTERFACE_FIELDS: &str =
    "iface.key iface.name iface.if_index iface.description iface.shutdown iface.vlan iface.vrf";

/// One `MTR_PATH` edge between two consecutive responding hops.
#[derive(Debug, Clone, PartialEq)]
pub struct MtrPath {
    /// `device.id`, or `mtr:<ip>` for a hop that resolved to no Device.
    pub source: String,
    pub target: String,
    /// Hop address; empty when the endpoint is a Device.
    pub source_addr: String,
    pub target_addr: String,
    pub avg_rtt_us: i64,
    pub loss_pct: f64,
    pub jitter_us: i64,
    pub from_hop: i64,
    pub to_hop: i64,
    pub agent_id: String,
    pub last_seen: String,
}

impl TopologyClient {
    /// Current (non-stale) MTR path edges, most recently observed first.
    /// `limit` is capped at [`MAX_MTR_PATHS`].
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if the query fails or the response is the
    /// wrong shape.
    pub async fn query_mtr_paths(&self, limit: usize) -> Result<Vec<MtrPath>, TopologyError> {
        let first = limit.clamp(1, MAX_MTR_PATHS);
        let query = format!(
            r#"{{
  paths(func: eq(topo.kind, "MTR_PATH"), orderdesc: topo.last_seen, first: {first}) @filter(NOT eq(topo.stale, true)) {{
    topo.agent_id
    topo.avg_rtt_us
    topo.loss_pct
    topo.jitter_us
    topo.from_hop
    topo.to_hop
    topo.last_seen
    topo.src {{ device.id hop.ip }}
    topo.dst {{ device.id hop.ip }}
  }}
}}"#
        );
        let parsed: MtrPathsQuery = self.read(&query).await?;
        Ok(parsed
            .paths
            .into_iter()
            .filter_map(MtrPathRow::into_path)
            .collect())
    }

    /// The device, its interfaces, and the peer interfaces its current
    /// `CONNECTS_TO` evidence reaches, in the `in:device_graph` result shape.
    /// `None` when no Device carries `device_id`.
    ///
    /// The topology graph holds no collector, service or capability
    /// vertices, so those arrays are always empty.
    ///
    /// # Errors
    ///
    /// Returns [`TopologyError`] if the id cannot be a DQL literal, the query
    /// fails, or the response is the wrong shape.
    pub async fn query_device_neighborhood(
        &self,
        device_id: &str,
        include_topology: bool,
    ) -> Result<Option<Value>, TopologyError> {
        let id = dql_string(device_id)?;
        let peer = format!(
            "device.id device.hostname device.ip device.interfaces {{ {INTERFACE_FIELDS} }}"
        );
        let edge_filter = r#"@filter(eq(topo.kind, "CONNECTS_TO") AND NOT eq(topo.stale, true))"#;
        let query = format!(
            r#"{{
  device(func: eq(device.id, {id}), first: 1) {{
    device.id
    device.hostname
    device.ip
    device.pkg_worst_severity
    device.pkg_critical_count
    device.pkg_kev_count
    device.pkg_has_unpatched_rce
    device.interfaces {{ {INTERFACE_FIELDS} }}
    outbound: ~topo.src {edge_filter} {{
      topo.if_name_ba
      topo.if_index_ba
      peer: topo.dst {{ {peer} }}
    }}
    inbound: ~topo.dst {edge_filter} {{
      topo.if_name_ab
      topo.if_index_ab
      peer: topo.src {{ {peer} }}
    }}
  }}
}}"#
        );
        let parsed: NeighborhoodQuery = self.read(&query).await?;
        Ok(parsed
            .device
            .into_iter()
            .next()
            .map(|device| device.into_neighborhood(include_topology)))
    }

    async fn read<T>(&self, query: &str) -> Result<T, TopologyError>
    where
        T: for<'de> Deserialize<'de>,
    {
        let response = self
            .dgraph()
            .new_read_only_txn()
            .query(query)
            .await
            .map_err(|err| TopologyError::from_dgraph(&err))?;
        serde_json::from_slice(response.json()).map_err(|err| TopologyError::Serde(err.to_string()))
    }
}

#[derive(Debug, Deserialize)]
struct MtrPathsQuery {
    #[serde(default)]
    paths: Vec<MtrPathRow>,
}

#[derive(Debug, Deserialize)]
struct MtrPathRow {
    #[serde(default, rename = "topo.agent_id")]
    agent_id: String,
    #[serde(default, rename = "topo.avg_rtt_us")]
    avg_rtt_us: i64,
    #[serde(default, rename = "topo.loss_pct")]
    loss_pct: f64,
    #[serde(default, rename = "topo.jitter_us")]
    jitter_us: i64,
    #[serde(default, rename = "topo.from_hop")]
    from_hop: i64,
    #[serde(default, rename = "topo.to_hop")]
    to_hop: i64,
    #[serde(default, rename = "topo.last_seen")]
    last_seen: String,
    #[serde(default, rename = "topo.src")]
    src: Vec<MtrEndpoint>,
    #[serde(default, rename = "topo.dst")]
    dst: Vec<MtrEndpoint>,
}

impl MtrPathRow {
    fn into_path(self) -> Option<MtrPath> {
        let (source, source_addr) = self.src.into_iter().next()?.identity()?;
        let (target, target_addr) = self.dst.into_iter().next()?.identity()?;
        Some(MtrPath {
            source,
            target,
            source_addr,
            target_addr,
            avg_rtt_us: self.avg_rtt_us,
            loss_pct: self.loss_pct,
            jitter_us: self.jitter_us,
            from_hop: self.from_hop,
            to_hop: self.to_hop,
            agent_id: self.agent_id,
            last_seen: self.last_seen,
        })
    }
}

#[derive(Debug, Deserialize)]
struct MtrEndpoint {
    #[serde(default, rename = "device.id")]
    device_id: Option<String>,
    #[serde(default, rename = "hop.ip")]
    hop_ip: Option<String>,
}

impl MtrEndpoint {
    fn identity(self) -> Option<(String, String)> {
        match (nonempty(self.device_id), nonempty(self.hop_ip)) {
            (Some(device), _) => Some((device, String::new())),
            (None, Some(ip)) => Some((format!("{MTR_HOP_ID_PREFIX}{ip}"), ip)),
            (None, None) => None,
        }
    }
}

#[derive(Debug, Deserialize)]
struct NeighborhoodQuery {
    #[serde(default)]
    device: Vec<NeighborhoodDevice>,
}

#[derive(Debug, Deserialize)]
struct NeighborhoodDevice {
    #[serde(flatten)]
    vertex: DeviceVertex,
    #[serde(default, rename = "device.interfaces")]
    interfaces: Vec<InterfaceVertex>,
    #[serde(default)]
    outbound: Vec<PeerEdge>,
    #[serde(default)]
    inbound: Vec<PeerEdge>,
}

impl NeighborhoodDevice {
    fn into_neighborhood(self, include_topology: bool) -> Value {
        let device_id = self.vertex.id.clone();
        let (interfaces, peer_interfaces) = if include_topology {
            let interfaces = self
                .interfaces
                .iter()
                .map(|iface| iface.to_json(&device_id))
                .collect::<Vec<_>>();
            let mut peers = Vec::new();
            for edge in self.outbound.into_iter().chain(self.inbound) {
                for peer in edge.peer_interfaces() {
                    if !peers.contains(&peer) {
                        peers.push(peer);
                    }
                }
            }
            (interfaces, peers)
        } else {
            (Vec::new(), Vec::new())
        };

        json!({
            "device": self.vertex.to_json(),
            "collectors": [],
            "services": [],
            "targets": [],
            "interfaces": interfaces,
            "peer_interfaces": peer_interfaces,
            "device_capabilities": [],
            "service_capabilities": [],
        })
    }
}

#[derive(Debug, Default, Deserialize)]
struct DeviceVertex {
    #[serde(default, rename = "device.id")]
    id: String,
    #[serde(default, rename = "device.hostname")]
    hostname: Option<String>,
    #[serde(default, rename = "device.ip")]
    ip: Option<String>,
    #[serde(default, rename = "device.pkg_worst_severity")]
    pkg_worst_severity: Option<String>,
    #[serde(default, rename = "device.pkg_critical_count")]
    pkg_critical_count: Option<i64>,
    #[serde(default, rename = "device.pkg_kev_count")]
    pkg_kev_count: Option<i64>,
    #[serde(default, rename = "device.pkg_has_unpatched_rce")]
    pkg_has_unpatched_rce: Option<bool>,
}

impl DeviceVertex {
    fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("id".into(), json!(self.id));
        insert_some(&mut map, "hostname", self.hostname.as_ref());
        insert_some(&mut map, "ip", self.ip.as_ref());
        insert_some(
            &mut map,
            "pkg_worst_severity",
            self.pkg_worst_severity.as_ref(),
        );
        insert_some(
            &mut map,
            "pkg_critical_count",
            self.pkg_critical_count.as_ref(),
        );
        insert_some(&mut map, "pkg_kev_count", self.pkg_kev_count.as_ref());
        insert_some(
            &mut map,
            "pkg_has_unpatched_rce",
            self.pkg_has_unpatched_rce.as_ref(),
        );
        Value::Object(map)
    }
}

#[derive(Debug, Deserialize)]
struct InterfaceVertex {
    #[serde(default, rename = "iface.key")]
    key: Option<String>,
    #[serde(default, rename = "iface.name")]
    name: Option<String>,
    #[serde(default, rename = "iface.if_index")]
    if_index: Option<i64>,
    #[serde(default, rename = "iface.description")]
    description: Option<String>,
    #[serde(default, rename = "iface.shutdown")]
    shutdown: Option<bool>,
    #[serde(default, rename = "iface.vlan")]
    vlan: Option<i64>,
    #[serde(default, rename = "iface.vrf")]
    vrf: Option<String>,
}

impl InterfaceVertex {
    fn matches(&self, name: &str, if_index: i64) -> bool {
        if !name.is_empty() {
            return self.name.as_deref() == Some(name);
        }
        if_index > 0 && self.if_index == Some(if_index)
    }

    fn to_json(&self, device_id: &str) -> Value {
        let mut map = Map::new();
        map.insert("id".into(), json!(self.key));
        map.insert("device_id".into(), json!(device_id));
        insert_some(&mut map, "name", self.name.as_ref());
        insert_some(&mut map, "ifindex", self.if_index.as_ref());
        insert_some(&mut map, "descr", self.description.as_ref());
        insert_some(&mut map, "shutdown", self.shutdown.as_ref());
        insert_some(&mut map, "vlan", self.vlan.as_ref());
        insert_some(&mut map, "vrf", self.vrf.as_ref());
        Value::Object(map)
    }
}

/// A `CONNECTS_TO` edge seen from the queried device: `name` / `if_index` are
/// the far end's port, from `if_*_ba` on an outbound edge and `if_*_ab` on an
/// inbound one.
#[derive(Debug, Deserialize)]
struct PeerEdge {
    #[serde(default, alias = "topo.if_name_ba", alias = "topo.if_name_ab")]
    name: String,
    #[serde(default, alias = "topo.if_index_ba", alias = "topo.if_index_ab")]
    if_index: i64,
    #[serde(default)]
    peer: Vec<PeerDevice>,
}

impl PeerEdge {
    fn peer_interfaces(&self) -> Vec<Value> {
        self.peer
            .iter()
            .filter(|device| !device.vertex.id.is_empty())
            .map(|device| device.peer_interface(&self.name, self.if_index))
            .collect()
    }
}

#[derive(Debug, Deserialize)]
struct PeerDevice {
    #[serde(flatten)]
    vertex: DeviceVertex,
    #[serde(default, rename = "device.interfaces")]
    interfaces: Vec<InterfaceVertex>,
}

impl PeerDevice {
    fn peer_interface(&self, name: &str, if_index: i64) -> Value {
        let owner = self.vertex.id.as_str();
        let iface = self
            .interfaces
            .iter()
            .find(|iface| iface.matches(name, if_index));
        let properties = match iface {
            Some(iface) => iface.to_json(owner),
            None => {
                let mut map = Map::new();
                map.insert("id".into(), Value::Null);
                map.insert("device_id".into(), json!(owner));
                if !name.is_empty() {
                    map.insert("name".into(), json!(name));
                }
                if if_index > 0 {
                    map.insert("ifindex".into(), json!(if_index));
                }
                Value::Object(map)
            }
        };
        let mut peer = properties.as_object().cloned().unwrap_or_default();
        peer.insert("owner_device_id".into(), json!(owner));
        peer.insert("owner_device".into(), self.vertex.to_json());
        peer.insert("properties".into(), properties);
        Value::Object(peer)
    }
}

fn insert_some<T: serde::Serialize>(map: &mut Map<String, Value>, key: &str, value: Option<&T>) {
    if let Some(value) = value {
        map.insert(key.into(), json!(value));
    }
}

fn nonempty(value: Option<String>) -> Option<String> {
    value.filter(|value| !value.is_empty())
}
