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

use crate::types::canonical_edge::link_key;

/// Kind stored on `topo.kind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EdgeKind {
    ConnectsTo,
    CanonicalTopology,
    LogicalPeer,
    HostedOn,
    InferredTo,
    AttachedTo,
    ObservedTo,
    MtrPath,
    ConfigDeclared,
}

impl EdgeKind {
    /// Dgraph stored name, matching the AGE relationship type where one exists.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ConnectsTo => "CONNECTS_TO",
            Self::CanonicalTopology => "CANONICAL_TOPOLOGY",
            Self::LogicalPeer => "LOGICAL_PEER",
            Self::HostedOn => "HOSTED_ON",
            Self::InferredTo => "INFERRED_TO",
            Self::AttachedTo => "ATTACHED_TO",
            Self::ObservedTo => "OBSERVED_TO",
            Self::MtrPath => "MTR_PATH",
            Self::ConfigDeclared => "CONFIG_DECLARED",
        }
    }
}

/// Device upsert payload. Fields are the Dgraph predicates; no config body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceWrite {
    id: String,
    hostname: Option<String>,
    ip: Option<String>,
    config_revision_id: Option<String>,
    pkg_worst_severity: Option<String>,
    pkg_critical_count: Option<i64>,
    pkg_kev_count: Option<i64>,
    pkg_has_unpatched_rce: Option<bool>,
    pkg_risk_summary_at: Option<String>,
}

impl DeviceWrite {
    #[must_use]
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            hostname: None,
            ip: None,
            config_revision_id: None,
            pkg_worst_severity: None,
            pkg_critical_count: None,
            pkg_kev_count: None,
            pkg_has_unpatched_rce: None,
            pkg_risk_summary_at: None,
        }
    }

    #[must_use]
    pub fn with_hostname(mut self, hostname: impl Into<String>) -> Self {
        self.hostname = Some(hostname.into());
        self
    }

    #[must_use]
    pub fn with_ip(mut self, ip: impl Into<String>) -> Self {
        self.ip = Some(ip.into());
        self
    }

    #[must_use]
    pub fn with_config_revision_id(mut self, revision_id: impl Into<String>) -> Self {
        self.config_revision_id = Some(revision_id.into());
        self
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn hostname(&self) -> Option<&str> {
        self.hostname.as_deref()
    }

    #[must_use]
    pub fn ip(&self) -> Option<&str> {
        self.ip.as_deref()
    }

    #[must_use]
    pub fn config_revision_id(&self) -> Option<&str> {
        self.config_revision_id.as_deref()
    }

    #[must_use]
    pub fn with_risk_summary(
        mut self,
        worst_severity: Option<String>,
        critical_count: Option<i64>,
        kev_count: Option<i64>,
        has_unpatched_rce: Option<bool>,
        risk_summary_at: Option<String>,
    ) -> Self {
        self.pkg_worst_severity = worst_severity;
        self.pkg_critical_count = critical_count;
        self.pkg_kev_count = kev_count;
        self.pkg_has_unpatched_rce = has_unpatched_rce;
        self.pkg_risk_summary_at = risk_summary_at;
        self
    }

    #[must_use]
    pub fn pkg_worst_severity(&self) -> Option<&str> {
        self.pkg_worst_severity.as_deref()
    }

    #[must_use]
    pub fn pkg_critical_count(&self) -> Option<i64> {
        self.pkg_critical_count
    }

    #[must_use]
    pub fn pkg_kev_count(&self) -> Option<i64> {
        self.pkg_kev_count
    }

    #[must_use]
    pub fn pkg_has_unpatched_rce(&self) -> Option<bool> {
        self.pkg_has_unpatched_rce
    }

    #[must_use]
    pub fn pkg_risk_summary_at(&self) -> Option<&str> {
        self.pkg_risk_summary_at.as_deref()
    }
}

/// Interface upsert payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterfaceWrite {
    key: String,
    device_id: String,
    name: Option<String>,
    if_index: Option<i32>,
}

impl InterfaceWrite {
    #[must_use]
    pub fn new(key: impl Into<String>, device_id: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            device_id: device_id.into(),
            name: None,
            if_index: None,
        }
    }

    #[must_use]
    pub fn with_name(mut self, name: impl Into<String>) -> Self {
        self.name = Some(name.into());
        self
    }

    #[must_use]
    pub fn with_if_index(mut self, if_index: i32) -> Self {
        self.if_index = Some(if_index);
        self
    }

    #[must_use]
    pub fn key(&self) -> &str {
        &self.key
    }

    #[must_use]
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    #[must_use]
    pub fn name(&self) -> Option<&str> {
        self.name.as_deref()
    }

    #[must_use]
    pub fn if_index(&self) -> Option<i32> {
        self.if_index
    }
}

/// Prefix upsert payload, keyed by CIDR.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrefixWrite {
    cidr: String,
    family: String,
}

impl PrefixWrite {
    #[must_use]
    pub fn new(cidr: impl Into<String>, family: impl Into<String>) -> Self {
        Self {
            cidr: cidr.into(),
            family: family.into(),
        }
    }

    #[must_use]
    pub fn cidr(&self) -> &str {
        &self.cidr
    }

    #[must_use]
    pub fn family(&self) -> &str {
        &self.family
    }
}

/// Change upsert payload. No ticket comments or config bodies.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangeWrite {
    id: String,
    kind: String,
    status: String,
    source: String,
    affects_prefix_cidrs: Vec<String>,
    affects_device_ids: Vec<String>,
}

impl ChangeWrite {
    #[must_use]
    pub fn new(
        id: impl Into<String>,
        kind: impl Into<String>,
        status: impl Into<String>,
        source: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            kind: kind.into(),
            status: status.into(),
            source: source.into(),
            affects_prefix_cidrs: Vec::new(),
            affects_device_ids: Vec::new(),
        }
    }

    #[must_use]
    pub fn with_prefix(mut self, cidr: impl Into<String>) -> Self {
        self.affects_prefix_cidrs.push(cidr.into());
        self
    }

    #[must_use]
    pub fn with_device(mut self, device_id: impl Into<String>) -> Self {
        self.affects_device_ids.push(device_id.into());
        self
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn kind(&self) -> &str {
        &self.kind
    }

    #[must_use]
    pub fn status(&self) -> &str {
        &self.status
    }

    #[must_use]
    pub fn source(&self) -> &str {
        &self.source
    }

    #[must_use]
    pub fn affects_prefix_cidrs(&self) -> &[String] {
        &self.affects_prefix_cidrs
    }

    #[must_use]
    pub fn affects_device_ids(&self) -> &[String] {
        &self.affects_device_ids
    }
}

/// HopNode upsert payload for MTR hops that are not Devices.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HopWrite {
    ip: String,
}

impl HopWrite {
    #[must_use]
    pub fn new(ip: impl Into<String>) -> Self {
        Self { ip: ip.into() }
    }

    #[must_use]
    pub fn ip(&self) -> &str {
        &self.ip
    }
}

/// Reified topology edge upsert payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EdgeWrite {
    source: String,
    target: String,
    if_name_ab: String,
    if_name_ba: String,
    if_index_ab: i32,
    if_index_ba: i32,
    kind: EdgeKind,
    protocol: String,
    evidence_class: String,
    ingestor: String,
    confidence_tier: String,
    flow_pps_ab: i64,
    flow_pps_ba: i64,
    flow_bps_ab: i64,
    flow_bps_ba: i64,
    capacity_bps: i64,
    telemetry_eligible: bool,
    last_seen: String,
    mutation_id: String,
    agent_id: Option<String>,
}

impl EdgeWrite {
    #[must_use]
    pub fn new(
        source: impl Into<String>,
        target: impl Into<String>,
        kind: EdgeKind,
        protocol: impl Into<String>,
        evidence_class: impl Into<String>,
        ingestor: impl Into<String>,
    ) -> Self {
        Self {
            source: source.into(),
            target: target.into(),
            if_name_ab: String::new(),
            if_name_ba: String::new(),
            if_index_ab: 0,
            if_index_ba: 0,
            kind,
            protocol: protocol.into(),
            evidence_class: evidence_class.into(),
            ingestor: ingestor.into(),
            confidence_tier: "high".to_string(),
            flow_pps_ab: 0,
            flow_pps_ba: 0,
            flow_bps_ab: 0,
            flow_bps_ba: 0,
            capacity_bps: 0,
            telemetry_eligible: false,
            last_seen: String::new(),
            mutation_id: String::new(),
            agent_id: None,
        }
    }

    #[must_use]
    pub fn canonical(
        source: impl Into<String>,
        target: impl Into<String>,
        protocol: impl Into<String>,
        evidence_class: impl Into<String>,
    ) -> Self {
        Self::new(
            source,
            target,
            EdgeKind::CanonicalTopology,
            protocol,
            evidence_class,
            "mapper_topology_v1",
        )
    }

    #[must_use]
    pub fn mapper_evidence(
        source: impl Into<String>,
        target: impl Into<String>,
        kind: EdgeKind,
        protocol: impl Into<String>,
        evidence_class: impl Into<String>,
    ) -> Self {
        Self::new(
            source,
            target,
            kind,
            protocol,
            evidence_class,
            "mapper_topology_v1",
        )
    }

    #[must_use]
    pub fn config_declared(source: impl Into<String>, target: impl Into<String>) -> Self {
        Self::new(
            source,
            target,
            EdgeKind::ConfigDeclared,
            "config",
            "config-declared",
            "network_config_v1",
        )
    }

    #[must_use]
    pub fn mtr_path(
        source: impl Into<String>,
        target: impl Into<String>,
        agent_id: impl Into<String>,
    ) -> Self {
        let mut write = Self::new(
            source,
            target,
            EdgeKind::MtrPath,
            "mtr",
            "path",
            "mtr_path_v1",
        );
        write.agent_id = Some(agent_id.into());
        write
    }

    #[must_use]
    pub fn with_interfaces(
        mut self,
        if_name_ab: impl Into<String>,
        if_index_ab: i32,
        if_name_ba: impl Into<String>,
        if_index_ba: i32,
    ) -> Self {
        self.if_name_ab = if_name_ab.into();
        self.if_index_ab = if_index_ab;
        self.if_name_ba = if_name_ba.into();
        self.if_index_ba = if_index_ba;
        self
    }

    #[must_use]
    pub fn with_flow(
        mut self,
        pps_ab: i64,
        pps_ba: i64,
        bps_ab: i64,
        bps_ba: i64,
        capacity_bps: i64,
        telemetry_eligible: bool,
    ) -> Self {
        self.flow_pps_ab = pps_ab;
        self.flow_pps_ba = pps_ba;
        self.flow_bps_ab = bps_ab;
        self.flow_bps_ba = bps_ba;
        self.capacity_bps = capacity_bps;
        self.telemetry_eligible = telemetry_eligible;
        self
    }

    #[must_use]
    pub fn with_confidence(mut self, tier: impl Into<String>) -> Self {
        self.confidence_tier = tier.into();
        self
    }

    #[must_use]
    pub fn with_last_seen(mut self, last_seen: impl Into<String>) -> Self {
        self.last_seen = last_seen.into();
        self
    }

    #[must_use]
    pub fn with_mutation_id(mut self, mutation_id: impl Into<String>) -> Self {
        self.mutation_id = mutation_id.into();
        self
    }

    #[must_use]
    pub fn with_agent_id(mut self, agent_id: impl Into<String>) -> Self {
        self.agent_id = Some(agent_id.into());
        self
    }

    #[must_use]
    pub fn link_key(&self) -> String {
        link_key(
            self.kind.as_str(),
            &self.source,
            &self.target,
            &self.if_name_ab,
            &self.if_name_ba,
        )
    }

    #[must_use]
    pub fn source(&self) -> &str {
        &self.source
    }

    #[must_use]
    pub fn target(&self) -> &str {
        &self.target
    }

    #[must_use]
    pub fn kind(&self) -> EdgeKind {
        self.kind
    }

    #[must_use]
    pub fn protocol(&self) -> &str {
        &self.protocol
    }

    #[must_use]
    pub fn evidence_class(&self) -> &str {
        &self.evidence_class
    }

    #[must_use]
    pub fn ingestor(&self) -> &str {
        &self.ingestor
    }

    #[must_use]
    pub fn confidence_tier(&self) -> &str {
        &self.confidence_tier
    }

    #[must_use]
    pub fn flow_pps_ab(&self) -> i64 {
        self.flow_pps_ab
    }

    #[must_use]
    pub fn flow_pps_ba(&self) -> i64 {
        self.flow_pps_ba
    }

    #[must_use]
    pub fn flow_bps_ab(&self) -> i64 {
        self.flow_bps_ab
    }

    #[must_use]
    pub fn flow_bps_ba(&self) -> i64 {
        self.flow_bps_ba
    }

    #[must_use]
    pub fn capacity_bps(&self) -> i64 {
        self.capacity_bps
    }

    #[must_use]
    pub fn telemetry_eligible(&self) -> bool {
        self.telemetry_eligible
    }

    #[must_use]
    pub fn if_index_ab(&self) -> i32 {
        self.if_index_ab
    }

    #[must_use]
    pub fn if_index_ba(&self) -> i32 {
        self.if_index_ba
    }

    #[must_use]
    pub fn if_name_ab(&self) -> &str {
        &self.if_name_ab
    }

    #[must_use]
    pub fn if_name_ba(&self) -> &str {
        &self.if_name_ba
    }

    #[must_use]
    pub fn last_seen(&self) -> &str {
        &self.last_seen
    }

    #[must_use]
    pub fn mutation_id(&self) -> &str {
        &self.mutation_id
    }

    #[must_use]
    pub fn agent_id(&self) -> Option<&str> {
        self.agent_id.as_deref()
    }
}
