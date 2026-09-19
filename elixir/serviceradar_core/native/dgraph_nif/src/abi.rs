// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Typed NIF ABI. Public-field maps live here so `dgraph-topology` stays
//! rustler-free. Writes convert into the kernel builders; DQL is read-only.

use dgraph_topology::{
    CanonicalEdge, ChangeWrite, DeviceWrite, EdgeKind, EdgeWrite, HopWrite, InterfaceWrite,
    NeighbourhoodEdge, PrefixWrite,
};
use rustler::{NifMap, NifTaggedEnum, NifUnitEnum};

/// Elixir atoms `:ok` / `{:error, reason}`.
#[derive(Clone, Debug, NifTaggedEnum)]
pub enum WriteResult {
    Ok,
    Error(String),
}

/// Elixir `{:ok, n}` / `{:error, reason}`.
#[derive(Clone, Debug, NifTaggedEnum)]
pub enum CountResult {
    Ok(u64),
    Error(String),
}

/// Elixir `{:ok, json}` / `{:error, reason}`.
#[derive(Clone, Debug, NifTaggedEnum)]
pub enum JsonResult {
    Ok(String),
    Error(String),
}

/// Elixir `{:ok, [edge]}` / `{:error, reason}`.
#[derive(Clone, Debug, NifTaggedEnum)]
pub enum CanonicalEdgesResult {
    Ok(Vec<NifCanonicalEdge>),
    Error(String),
}

/// Elixir `{:ok, [edge]}` / `{:error, reason}`.
#[derive(Clone, Debug, NifTaggedEnum)]
pub enum NeighbourhoodResult {
    Ok(Vec<NifNeighbourhoodEdge>),
    Error(String),
}

/// Stored `topo.kind`. Encodes as `:connects_to`, `:canonical_topology`, …
#[derive(Clone, Copy, Debug, PartialEq, Eq, NifUnitEnum)]
pub enum NifEdgeKind {
    ConnectsTo,
    CanonicalTopology,
    LogicalPeer,
    HostedOn,
    InferredTo,
    AttachedTo,
    MtrPath,
    ConfigDeclared,
}

impl From<NifEdgeKind> for EdgeKind {
    fn from(kind: NifEdgeKind) -> Self {
        match kind {
            NifEdgeKind::ConnectsTo => Self::ConnectsTo,
            NifEdgeKind::CanonicalTopology => Self::CanonicalTopology,
            NifEdgeKind::LogicalPeer => Self::LogicalPeer,
            NifEdgeKind::HostedOn => Self::HostedOn,
            NifEdgeKind::InferredTo => Self::InferredTo,
            NifEdgeKind::AttachedTo => Self::AttachedTo,
            NifEdgeKind::MtrPath => Self::MtrPath,
            NifEdgeKind::ConfigDeclared => Self::ConfigDeclared,
        }
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifDeviceWrite {
    pub id: String,
    pub hostname: Option<String>,
    pub ip: Option<String>,
    pub config_revision_id: Option<String>,
    pub pkg_worst_severity: Option<String>,
    pub pkg_critical_count: Option<i64>,
    pub pkg_kev_count: Option<i64>,
    pub pkg_has_unpatched_rce: Option<bool>,
    pub pkg_risk_summary_at: Option<String>,
}

impl NifDeviceWrite {
    pub fn into_write(self) -> DeviceWrite {
        let mut write = DeviceWrite::new(self.id);
        if let Some(hostname) = nonempty(self.hostname) {
            write = write.with_hostname(hostname);
        }
        if let Some(ip) = nonempty(self.ip) {
            write = write.with_ip(ip);
        }
        if let Some(revision) = nonempty(self.config_revision_id) {
            write = write.with_config_revision_id(revision);
        }
        write = write.with_risk_summary(
            nonempty(self.pkg_worst_severity),
            self.pkg_critical_count,
            self.pkg_kev_count,
            self.pkg_has_unpatched_rce,
            nonempty(self.pkg_risk_summary_at),
        );
        write
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifInterfaceWrite {
    pub key: String,
    pub device_id: String,
    pub name: Option<String>,
    pub if_index: Option<i32>,
}

impl NifInterfaceWrite {
    pub fn into_write(self) -> InterfaceWrite {
        let mut write = InterfaceWrite::new(self.key, self.device_id);
        if let Some(name) = nonempty(self.name) {
            write = write.with_name(name);
        }
        if let Some(if_index) = self.if_index {
            write = write.with_if_index(if_index);
        }
        write
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifPrefixWrite {
    pub cidr: String,
    pub family: String,
}

impl NifPrefixWrite {
    pub fn into_write(self) -> PrefixWrite {
        PrefixWrite::new(self.cidr, self.family)
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifChangeWrite {
    pub id: String,
    pub kind: String,
    pub status: String,
    pub source: String,
    pub affects_prefix_cidrs: Vec<String>,
    pub affects_device_ids: Vec<String>,
}

impl NifChangeWrite {
    pub fn into_write(self) -> ChangeWrite {
        let mut write = ChangeWrite::new(self.id, self.kind, self.status, self.source);
        for cidr in self.affects_prefix_cidrs {
            write = write.with_prefix(cidr);
        }
        for device_id in self.affects_device_ids {
            write = write.with_device(device_id);
        }
        write
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifHopWrite {
    pub ip: String,
}

impl NifHopWrite {
    pub fn into_write(self) -> HopWrite {
        HopWrite::new(self.ip)
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifEdgeWrite {
    pub source: String,
    pub target: String,
    pub kind: NifEdgeKind,
    pub protocol: String,
    pub evidence_class: String,
    pub ingestor: String,
    pub if_name_ab: Option<String>,
    pub if_name_ba: Option<String>,
    pub if_index_ab: Option<i32>,
    pub if_index_ba: Option<i32>,
    pub confidence_tier: Option<String>,
    pub flow_pps_ab: Option<i64>,
    pub flow_pps_ba: Option<i64>,
    pub flow_bps_ab: Option<i64>,
    pub flow_bps_ba: Option<i64>,
    pub capacity_bps: Option<i64>,
    pub telemetry_eligible: Option<bool>,
    pub last_seen: Option<String>,
    pub mutation_id: Option<String>,
    pub agent_id: Option<String>,
}

impl NifEdgeWrite {
    pub fn into_write(self) -> EdgeWrite {
        let mut write = EdgeWrite::new(
            self.source,
            self.target,
            self.kind.into(),
            self.protocol,
            self.evidence_class,
            self.ingestor,
        );
        write = write.with_interfaces(
            self.if_name_ab.unwrap_or_default(),
            self.if_index_ab.unwrap_or(0),
            self.if_name_ba.unwrap_or_default(),
            self.if_index_ba.unwrap_or(0),
        );
        write = write.with_flow(
            self.flow_pps_ab.unwrap_or(0),
            self.flow_pps_ba.unwrap_or(0),
            self.flow_bps_ab.unwrap_or(0),
            self.flow_bps_ba.unwrap_or(0),
            self.capacity_bps.unwrap_or(0),
            self.telemetry_eligible.unwrap_or(false),
        );
        if let Some(tier) = nonempty(self.confidence_tier) {
            write = write.with_confidence(tier);
        }
        if let Some(last_seen) = nonempty(self.last_seen) {
            write = write.with_last_seen(last_seen);
        }
        if let Some(mutation_id) = nonempty(self.mutation_id) {
            write = write.with_mutation_id(mutation_id);
        }
        if let Some(agent_id) = nonempty(self.agent_id) {
            write = write.with_agent_id(agent_id);
        }
        write
    }
}

#[derive(Clone, Debug, PartialEq, Eq, NifMap)]
pub struct NifCanonicalEdge {
    pub source: String,
    pub target: String,
    pub flow_pps: i64,
    pub flow_bps: i64,
    pub flow_pps_ab: i64,
    pub flow_pps_ba: i64,
    pub flow_bps_ab: i64,
    pub flow_bps_ba: i64,
    pub capacity_bps: i64,
    pub telemetry_eligible: bool,
    pub protocol: String,
    pub evidence_class: String,
    pub confidence_tier: String,
    pub if_index_ab: i32,
    pub if_name_ab: String,
    pub if_index_ba: i32,
    pub if_name_ba: String,
    pub link_key: String,
    pub mutation_id: String,
}

impl From<&CanonicalEdge> for NifCanonicalEdge {
    fn from(edge: &CanonicalEdge) -> Self {
        Self {
            source: edge.source().to_string(),
            target: edge.target().to_string(),
            flow_pps: edge.flow_pps(),
            flow_bps: edge.flow_bps(),
            flow_pps_ab: edge.flow_pps_ab(),
            flow_pps_ba: edge.flow_pps_ba(),
            flow_bps_ab: edge.flow_bps_ab(),
            flow_bps_ba: edge.flow_bps_ba(),
            capacity_bps: edge.capacity_bps(),
            telemetry_eligible: edge.telemetry_eligible(),
            protocol: edge.protocol().to_string(),
            evidence_class: edge.evidence_class().to_string(),
            confidence_tier: edge.confidence_tier().to_string(),
            if_index_ab: edge.local_if_index_ab(),
            if_name_ab: edge.local_if_name_ab().to_string(),
            if_index_ba: edge.local_if_index_ba(),
            if_name_ba: edge.local_if_name_ba().to_string(),
            link_key: edge.link_key().to_string(),
            mutation_id: edge.mutation_id().to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, NifMap)]
pub struct NifNeighbourhoodEdge {
    pub kind: String,
    pub source: String,
    pub target: String,
    pub flow_pps: i64,
    pub flow_bps: i64,
    pub flow_pps_ab: i64,
    pub flow_pps_ba: i64,
    pub flow_bps_ab: i64,
    pub flow_bps_ba: i64,
    pub capacity_bps: i64,
    pub telemetry_eligible: bool,
    pub protocol: String,
    pub evidence_class: String,
    pub confidence_tier: String,
    pub if_index_ab: i32,
    pub if_name_ab: String,
    pub if_index_ba: i32,
    pub if_name_ba: String,
    pub link_key: String,
    pub mutation_id: String,
}

impl From<&NeighbourhoodEdge> for NifNeighbourhoodEdge {
    fn from(row: &NeighbourhoodEdge) -> Self {
        let edge = NifCanonicalEdge::from(row.edge());
        Self {
            kind: row.kind().to_string(),
            source: edge.source,
            target: edge.target,
            flow_pps: edge.flow_pps,
            flow_bps: edge.flow_bps,
            flow_pps_ab: edge.flow_pps_ab,
            flow_pps_ba: edge.flow_pps_ba,
            flow_bps_ab: edge.flow_bps_ab,
            flow_bps_ba: edge.flow_bps_ba,
            capacity_bps: edge.capacity_bps,
            telemetry_eligible: edge.telemetry_eligible,
            protocol: edge.protocol,
            evidence_class: edge.evidence_class,
            confidence_tier: edge.confidence_tier,
            if_index_ab: edge.if_index_ab,
            if_name_ab: edge.if_name_ab,
            if_index_ba: edge.if_index_ba,
            if_name_ba: edge.if_name_ba,
            link_key: edge.link_key,
            mutation_id: edge.mutation_id,
        }
    }
}

/// True when the DQL escape hatch must refuse rather than submit a mutation.
#[must_use]
pub fn refuses_mutation(dql: &str) -> bool {
    let collapsed = collapse_ws(dql);
    collapsed.contains("mutation ")
        || collapsed.contains("mutation{")
        || collapsed.contains("set {")
        || collapsed.contains("set{")
        || collapsed.contains("delete {")
        || collapsed.contains("delete{")
        || collapsed.contains("upsert {")
        || collapsed.contains("upsert{")
}

fn collapse_ws(dql: &str) -> String {
    dql.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase()
}

fn nonempty(value: Option<String>) -> Option<String> {
    value.filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_only_dql_is_allowed() {
        assert!(!refuses_mutation(
            "{ q(func: eq(device.id, \"sr:host01.example.com\")) { device.id } }"
        ));
        assert!(!refuses_mutation(
            "{ q(func: eq(device.id, \"mutation-lab\")) { uid } }"
        ));
    }

    #[test]
    fn mutation_blocks_are_refused() {
        assert!(refuses_mutation(
            "mutation { set { _:x <dgraph.type> \"Device\" } }"
        ));
        assert!(refuses_mutation(
            "set { _:x <device.id> \"sr:host01.example.com\" }"
        ));
        assert!(refuses_mutation("delete { uid(v) * * . }"));
        assert!(refuses_mutation(
            "upsert { query { q(func: uid(0x1)) { uid } } }"
        ));
        assert!(refuses_mutation(
            "MUTATION{\n  set { _:x <dgraph.type> \"Device\" }\n}"
        ));
    }

    #[test]
    fn device_write_drops_empty_optionals() {
        let write = NifDeviceWrite {
            id: "sr:host01.example.com".to_string(),
            hostname: Some(String::new()),
            ip: None,
            config_revision_id: Some("rev-1".to_string()),
            pkg_worst_severity: None,
            pkg_critical_count: None,
            pkg_kev_count: None,
            pkg_has_unpatched_rce: None,
            pkg_risk_summary_at: None,
        }
        .into_write();
        assert_eq!(write.id(), "sr:host01.example.com");
        assert_eq!(write.hostname(), None);
        assert_eq!(write.ip(), None);
        assert_eq!(write.config_revision_id(), Some("rev-1"));
    }

    #[test]
    fn edge_kind_maps_to_stored_name() {
        let write = NifEdgeWrite {
            source: "sr:host01.example.com".to_string(),
            target: "sr:host02.example.com".to_string(),
            kind: NifEdgeKind::CanonicalTopology,
            protocol: "snmp-l2".to_string(),
            evidence_class: "direct".to_string(),
            ingestor: "mapper_topology_v1".to_string(),
            if_name_ab: Some("eth1".to_string()),
            if_name_ba: Some("eth2".to_string()),
            if_index_ab: Some(1),
            if_index_ba: Some(2),
            confidence_tier: None,
            flow_pps_ab: None,
            flow_pps_ba: None,
            flow_bps_ab: None,
            flow_bps_ba: None,
            capacity_bps: None,
            telemetry_eligible: None,
            last_seen: None,
            mutation_id: None,
            agent_id: None,
        }
        .into_write();
        assert_eq!(write.kind().as_str(), "CANONICAL_TOPOLOGY");
        assert_eq!(write.if_name_ab(), "eth1");
        assert_eq!(write.if_index_ba(), 2);
        assert_eq!(
            write.link_key(),
            "sr:host01.example.com|sr:host02.example.com|eth1|eth2"
        );
    }
}
