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

use super::{CanonicalEdge, NeighbourhoodEdge};

/// Canonical vertices and relations read from one Dgraph transaction snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonicalGraph {
    nodes: Vec<CanonicalDevice>,
    edges: Vec<CanonicalEdge>,
}

impl CanonicalGraph {
    pub(crate) fn new(nodes: Vec<CanonicalDevice>, edges: Vec<CanonicalEdge>) -> Self {
        Self { nodes, edges }
    }

    #[must_use]
    pub fn nodes(&self) -> &[CanonicalDevice] {
        &self.nodes
    }

    #[must_use]
    pub fn edges(&self) -> &[CanonicalEdge] {
        &self.edges
    }

    /// Consume a snapshot without copying the full graph across the native boundary.
    #[must_use]
    pub fn into_parts(self) -> (Vec<CanonicalDevice>, Vec<CanonicalEdge>) {
        (self.nodes, self.edges)
    }
}

/// Minimal canonical identity; inventory enrichment happens after level selection.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub struct CanonicalDevice {
    #[serde(rename = "device.id")]
    id: String,
    #[serde(rename = "device.hostname")]
    hostname: Option<String>,
    #[serde(rename = "device.ip")]
    ip: Option<String>,
}

impl CanonicalDevice {
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
}

/// One read-only snapshot of the tiled world: the canonical backbone plus
/// mapper-admitted attachment, inferred, and hosted edges.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TopologyView {
    nodes: Vec<CanonicalDevice>,
    edges: Vec<NeighbourhoodEdge>,
}

impl TopologyView {
    #[must_use]
    pub fn new(nodes: Vec<CanonicalDevice>, edges: Vec<NeighbourhoodEdge>) -> Self {
        Self { nodes, edges }
    }

    #[must_use]
    pub fn nodes(&self) -> &[CanonicalDevice] {
        &self.nodes
    }

    #[must_use]
    pub fn edges(&self) -> &[NeighbourhoodEdge] {
        &self.edges
    }

    #[must_use]
    pub fn into_parts(self) -> (Vec<CanonicalDevice>, Vec<NeighbourhoodEdge>) {
        (self.nodes, self.edges)
    }
}
