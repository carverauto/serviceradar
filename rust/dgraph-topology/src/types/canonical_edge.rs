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

/// Render-ready directional edge God View already consumes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonicalEdge {
    source: String,
    target: String,
    flow_pps: i64,
    flow_bps: i64,
    flow_pps_ab: i64,
    flow_pps_ba: i64,
    flow_bps_ab: i64,
    flow_bps_ba: i64,
    capacity_bps: i64,
    telemetry_eligible: bool,
    protocol: String,
    evidence_class: String,
    confidence_tier: String,
    local_if_index_ab: i32,
    local_if_name_ab: String,
    local_if_index_ba: i32,
    local_if_name_ba: String,
    link_key: String,
    mutation_id: String,
}

impl CanonicalEdge {
    /// Build a render-ready edge from typed fields.
    #[allow(clippy::too_many_arguments)]
    #[must_use]
    pub fn new(
        source: String,
        target: String,
        flow_pps_ab: i64,
        flow_pps_ba: i64,
        flow_bps_ab: i64,
        flow_bps_ba: i64,
        capacity_bps: i64,
        telemetry_eligible: bool,
        protocol: String,
        evidence_class: String,
        confidence_tier: String,
        local_if_index_ab: i32,
        local_if_name_ab: String,
        local_if_index_ba: i32,
        local_if_name_ba: String,
        link_key: String,
        mutation_id: String,
    ) -> Self {
        Self {
            flow_pps: flow_pps_ab.saturating_add(flow_pps_ba),
            flow_bps: flow_bps_ab.saturating_add(flow_bps_ba),
            source,
            target,
            flow_pps_ab,
            flow_pps_ba,
            flow_bps_ab,
            flow_bps_ba,
            capacity_bps,
            telemetry_eligible,
            protocol,
            evidence_class,
            confidence_tier,
            local_if_index_ab,
            local_if_name_ab,
            local_if_index_ba,
            local_if_name_ba,
            link_key,
            mutation_id,
        }
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
    pub fn flow_pps(&self) -> i64 {
        self.flow_pps
    }

    #[must_use]
    pub fn flow_bps(&self) -> i64 {
        self.flow_bps
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
    pub fn protocol(&self) -> &str {
        &self.protocol
    }

    #[must_use]
    pub fn evidence_class(&self) -> &str {
        &self.evidence_class
    }

    #[must_use]
    pub fn confidence_tier(&self) -> &str {
        &self.confidence_tier
    }

    #[must_use]
    pub fn local_if_index_ab(&self) -> i32 {
        self.local_if_index_ab
    }

    #[must_use]
    pub fn local_if_name_ab(&self) -> &str {
        &self.local_if_name_ab
    }

    #[must_use]
    pub fn local_if_index_ba(&self) -> i32 {
        self.local_if_index_ba
    }

    #[must_use]
    pub fn local_if_name_ba(&self) -> &str {
        &self.local_if_name_ba
    }

    #[must_use]
    pub fn link_key(&self) -> &str {
        &self.link_key
    }

    #[must_use]
    pub fn mutation_id(&self) -> &str {
        &self.mutation_id
    }
}

/// An edge incident on a device, including non-canonical `topo.kind` values.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NeighbourhoodEdge {
    kind: String,
    edge: CanonicalEdge,
}

impl NeighbourhoodEdge {
    /// Pair a stored `topo.kind` with the God View edge shape.
    #[must_use]
    pub fn new(kind: impl Into<String>, edge: CanonicalEdge) -> Self {
        Self {
            kind: kind.into(),
            edge,
        }
    }

    #[must_use]
    pub fn kind(&self) -> &str {
        &self.kind
    }

    #[must_use]
    pub fn edge(&self) -> &CanonicalEdge {
        &self.edge
    }
}

/// Idempotency key for a projected link: source, target, and both interface keys.
#[must_use]
pub fn link_key(source: &str, target: &str, if_ab: &str, if_ba: &str) -> String {
    format!("{source}|{target}|{if_ab}|{if_ba}")
}
