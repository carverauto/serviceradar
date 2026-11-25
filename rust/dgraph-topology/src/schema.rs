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

//! Namespaced topology schema.
//!
//! Dgraph predicates are global to a namespace. Unprefixed `id` / `name`
//! collide. Do not use `svc.` or `endpoint.` — those belong to scrith.

use dgraph_migrate::SchemaSpec;

/// Device identity: the canonical `sr:`-prefixed `ocsf_devices.uid`.
pub const PRED_DEVICE_ID: &str = "device.id";

/// Idempotency key for a reified topology edge.
pub const PRED_LINK_KEY: &str = "topo.link_key";

/// Prefix identity: the CIDR string.
pub const PRED_PREFIX_CIDR: &str = "prefix.cidr";

/// Change identity: the external change id.
pub const PRED_CHANGE_ID: &str = "change.id";

/// External entity identity: canonical ID from Horizon topology snapshots.
pub const PRED_EXT_ID: &str = "ext.id";

/// Ingestor tag stamped on external topology projections.
pub const HORIZON_INGESTOR: &str = "horizon_topology_v1";

/// DQL schema applied by the migrator.
pub const SCHEMA: &str = r#"
device.id: string @index(exact) @upsert .
device.hostname: string @index(exact) .
device.ip: string @index(exact) .
device.config_revision_id: string @index(exact) .
device.interfaces: [uid] @reverse .
device.pkg_worst_severity: string .
device.pkg_critical_count: int .
device.pkg_kev_count: int .
device.pkg_has_unpatched_rce: bool .
device.pkg_risk_summary_at: datetime .

iface.key: string @index(exact) @upsert .
iface.name: string @index(exact) .
iface.if_index: int @index(int) .
iface.description: string .
iface.shutdown: bool @index(bool) .
iface.vlan: int .
iface.vrf: string @index(exact) .
iface.prefixes: [uid] @reverse .

hop.ip: string @index(exact) @upsert .

collector.id: string @index(exact) @upsert .
collector.kind: string @index(exact) .

topo.link_key: string @index(exact) @upsert .
topo.src: [uid] @reverse .
topo.dst: [uid] @reverse .
topo.kind: string @index(exact) .
topo.protocol: string @index(exact) .
topo.evidence_class: string @index(exact) .
topo.ingestor: string @index(exact) .
topo.confidence_tier: string @index(exact) .
topo.confidence_score: float .
topo.flow_pps_ab: int .
topo.flow_pps_ba: int .
topo.flow_bps_ab: int .
topo.flow_bps_ba: int .
topo.capacity_bps: int .
topo.telemetry_eligible: bool @index(bool) .
topo.if_index_ab: int .
topo.if_index_ba: int .
topo.if_name_ab: string .
topo.if_name_ba: string .
topo.pair_support_rank: int .
topo.last_seen: datetime @index(hour) .
topo.stale: bool @index(bool) .
topo.agent_id: string @index(exact) .
topo.avg_rtt_us: int .
topo.loss_pct: float .
topo.jitter_us: int .
topo.from_hop: int .
topo.to_hop: int .
topo.mutation_id: string @index(exact) .
topo.border_asn: int @index(int) .
topo.as_boundary_confidence: float .
topo.expires_at: datetime @index(hour) .
topo.ttl_secs: int .

prefix.cidr: string @index(exact) @upsert .
prefix.family: string @index(exact) .
prefix.asn: int @index(int) .
prefix.rpki_state: string @index(exact) .
prefix.rtbh_active: bool @index(bool) .
prefix.max_length: int .
prefix.irr_status: string @index(exact) .
prefix.last_seen: datetime @index(hour) .
prefix.expires_at: datetime @index(hour) .

change.id: string @index(exact) @upsert .
change.kind: string @index(exact) .
change.window_start: datetime @index(hour) .
change.window_end: datetime @index(hour) .
change.status: string @index(exact) .
change.source: string @index(exact) .
change.affects: [uid] @reverse .

ext.id: string @index(exact) @upsert .
ext.kind: string @index(exact) .
ext.asn: int @index(int) .
ext.label: string @index(exact) .
ext.region: string @index(exact) .
ext.ip: string @index(exact) .
ext.rpki_state: string @index(exact) .
ext.rtbh_active: bool @index(bool) .
ext.metro: string @index(exact) .
ext.iata: string @index(exact) .
ext.country_code: string @index(exact) .
ext.outage_state: string @index(exact) .
ext.ingestor: string @index(exact) .
ext.last_seen: datetime @index(hour) .
ext.expires_at: datetime @index(hour) .
ext.stale: bool @index(bool) .

type Device {
  device.id
  device.hostname
  device.ip
  device.config_revision_id
  device.interfaces
  device.pkg_worst_severity
  device.pkg_critical_count
  device.pkg_kev_count
  device.pkg_has_unpatched_rce
  device.pkg_risk_summary_at
}

type Interface {
  iface.key
  iface.name
  iface.if_index
  iface.description
  iface.shutdown
  iface.vlan
  iface.vrf
  iface.prefixes
}

type HopNode {
  hop.ip
}

type Collector {
  collector.id
  collector.kind
}

type Service {
  collector.id
  collector.kind
}

type TopologyEdge {
  topo.link_key
  topo.src
  topo.dst
  topo.kind
  topo.protocol
  topo.evidence_class
  topo.ingestor
  topo.confidence_tier
  topo.confidence_score
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
  topo.pair_support_rank
  topo.last_seen
  topo.stale
  topo.agent_id
  topo.avg_rtt_us
  topo.loss_pct
  topo.jitter_us
  topo.from_hop
  topo.to_hop
  topo.mutation_id
  topo.border_asn
  topo.as_boundary_confidence
  topo.expires_at
  topo.ttl_secs
}

type Prefix {
  prefix.cidr
  prefix.family
  prefix.asn
  prefix.rpki_state
  prefix.rtbh_active
  prefix.max_length
  prefix.irr_status
  prefix.last_seen
  prefix.expires_at
}

type Change {
  change.id
  change.kind
  change.window_start
  change.window_end
  change.status
  change.source
  change.affects
}

type Vantage {
  ext.id
  ext.kind
  ext.asn
  ext.label
  ext.region
  ext.ip
  ext.iata
  ext.country_code
  ext.ingestor
  ext.last_seen
  ext.expires_at
  ext.stale
}

type TransitRouter {
  ext.id
  ext.kind
  ext.asn
  ext.label
  ext.region
  ext.ip
  ext.rpki_state
  ext.rtbh_active
  ext.ingestor
  ext.last_seen
  ext.expires_at
  ext.stale
}

type IXP {
  ext.id
  ext.kind
  ext.label
  ext.region
  ext.metro
  ext.iata
  ext.country_code
  ext.ingestor
  ext.last_seen
  ext.expires_at
  ext.stale
}

type Facility {
  ext.id
  ext.kind
  ext.label
  ext.region
  ext.metro
  ext.country_code
  ext.ingestor
  ext.last_seen
  ext.expires_at
  ext.stale
}

type ASN {
  ext.id
  ext.kind
  ext.asn
  ext.label
  ext.region
  ext.rpki_state
  ext.rtbh_active
  ext.ingestor
  ext.last_seen
  ext.expires_at
  ext.stale
}

type AnycastPop {
  ext.id
  ext.kind
  ext.asn
  ext.label
  ext.region
  ext.metro
  ext.iata
  ext.country_code
  ext.outage_state
  ext.ingestor
  ext.last_seen
  ext.expires_at
  ext.stale
}

type SaasTarget {
  ext.id
  ext.kind
  ext.asn
  ext.label
  ext.region
  ext.ip
  ext.outage_state
  ext.ingestor
  ext.last_seen
  ext.expires_at
  ext.stale
}
"#;

/// Predicates this schema owns, in declaration order.
pub const PREDICATES: &[&str] = &[
    "device.id",
    "device.hostname",
    "device.ip",
    "device.config_revision_id",
    "device.interfaces",
    "device.pkg_worst_severity",
    "device.pkg_critical_count",
    "device.pkg_kev_count",
    "device.pkg_has_unpatched_rce",
    "device.pkg_risk_summary_at",
    "iface.key",
    "iface.name",
    "iface.if_index",
    "iface.description",
    "iface.shutdown",
    "iface.vlan",
    "iface.vrf",
    "iface.prefixes",
    "hop.ip",
    "collector.id",
    "collector.kind",
    "topo.link_key",
    "topo.src",
    "topo.dst",
    "topo.kind",
    "topo.protocol",
    "topo.evidence_class",
    "topo.ingestor",
    "topo.confidence_tier",
    "topo.confidence_score",
    "topo.flow_pps_ab",
    "topo.flow_pps_ba",
    "topo.flow_bps_ab",
    "topo.flow_bps_ba",
    "topo.capacity_bps",
    "topo.telemetry_eligible",
    "topo.if_index_ab",
    "topo.if_index_ba",
    "topo.if_name_ab",
    "topo.if_name_ba",
    "topo.pair_support_rank",
    "topo.last_seen",
    "topo.stale",
    "topo.agent_id",
    "topo.avg_rtt_us",
    "topo.loss_pct",
    "topo.jitter_us",
    "topo.from_hop",
    "topo.to_hop",
    "topo.mutation_id",
    "topo.border_asn",
    "topo.as_boundary_confidence",
    "topo.expires_at",
    "topo.ttl_secs",
    "prefix.cidr",
    "prefix.family",
    "prefix.asn",
    "prefix.rpki_state",
    "prefix.rtbh_active",
    "prefix.max_length",
    "prefix.irr_status",
    "prefix.last_seen",
    "prefix.expires_at",
    "change.id",
    "change.kind",
    "change.window_start",
    "change.window_end",
    "change.status",
    "change.source",
    "change.affects",
    "ext.id",
    "ext.kind",
    "ext.asn",
    "ext.label",
    "ext.region",
    "ext.ip",
    "ext.rpki_state",
    "ext.rtbh_active",
    "ext.metro",
    "ext.iata",
    "ext.country_code",
    "ext.outage_state",
    "ext.ingestor",
    "ext.last_seen",
    "ext.expires_at",
    "ext.stale",
];

/// Types this schema owns.
pub const TYPES: &[&str] = &[
    "Device",
    "Interface",
    "HopNode",
    "Collector",
    "Service",
    "TopologyEdge",
    "Prefix",
    "Change",
    "Vantage",
    "TransitRouter",
    "IXP",
    "Facility",
    "ASN",
    "AnycastPop",
    "SaasTarget",
];

/// Spec consumed by `dgraph-migrate`.
#[must_use]
pub const fn schema_spec() -> SchemaSpec {
    SchemaSpec::new(SCHEMA, PREDICATES, TYPES)
}
