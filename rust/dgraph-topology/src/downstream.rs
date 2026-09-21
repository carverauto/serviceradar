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

//! Graph fact: is set B reachable downstream of set A on canonical topology.
//! This is not a postpone/sequence verdict.

use std::collections::{HashMap, HashSet, VecDeque};

use crate::types::CanonicalEdge;

/// Result of a downstream-of walk. Never postpone or sequence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DownstreamFact {
    Reachable,
    Disjoint,
}

/// True when `id` looks like a CIDR selector (contains `/`).
#[must_use]
pub fn looks_like_cidr(id: &str) -> bool {
    id.contains('/')
}

/// BFS from `from` along canonical edges. Hits any `to` → Reachable.
#[must_use]
pub fn reachable_on_canonical(
    edges: &[CanonicalEdge],
    from: &HashSet<String>,
    to: &HashSet<String>,
) -> DownstreamFact {
    if from.is_empty() || to.is_empty() {
        return DownstreamFact::Disjoint;
    }
    if from.iter().any(|id| to.contains(id)) {
        return DownstreamFact::Reachable;
    }

    let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();
    for edge in edges {
        adj.entry(edge.source()).or_default().push(edge.target());
    }

    let mut seen: HashSet<&str> = HashSet::new();
    let mut queue: VecDeque<&str> = VecDeque::new();
    for id in from {
        if seen.insert(id.as_str()) {
            queue.push_back(id.as_str());
        }
    }

    while let Some(node) = queue.pop_front() {
        if to.contains(node) {
            return DownstreamFact::Reachable;
        }
        if let Some(next) = adj.get(node) {
            for dest in next {
                if seen.insert(dest) {
                    queue.push_back(dest);
                }
            }
        }
    }
    DownstreamFact::Disjoint
}

#[cfg(test)]
mod tests {
    use super::{DownstreamFact, looks_like_cidr, reachable_on_canonical};
    use crate::types::CanonicalEdge;
    use std::collections::HashSet;

    fn edge(src: &str, dst: &str) -> CanonicalEdge {
        CanonicalEdge::new(
            src.to_string(),
            dst.to_string(),
            0,
            0,
            0,
            0,
            0,
            false,
            "lldp".to_string(),
            "direct-physical".to_string(),
            "high".to_string(),
            0,
            String::new(),
            0,
            String::new(),
            format!("{src}|{dst}"),
            String::new(),
        )
    }

    #[test]
    fn cidr_selectors_are_detected() {
        assert!(looks_like_cidr("192.0.2.0/24"));
        assert!(looks_like_cidr("2001:db8:1::/64"));
        assert!(!looks_like_cidr("sr:host01.example.com"));
    }

    #[test]
    fn prefix_b_is_downstream_of_prefix_a_device() {
        // Change A affects 192.0.2.0/24 → device 192.0.2.1
        // Change B affects 198.51.100.0/24 → device 198.51.100.1
        // Canonical: 192.0.2.1 → 198.51.100.1
        let edges = [edge("sr:192.0.2.1", "sr:198.51.100.1")];
        let from = HashSet::from(["sr:192.0.2.1".to_string()]);
        let to = HashSet::from(["sr:198.51.100.1".to_string()]);
        assert_eq!(
            reachable_on_canonical(&edges, &from, &to),
            DownstreamFact::Reachable
        );
    }

    #[test]
    fn disjoint_topology_is_not_reachable() {
        let edges = [edge("sr:192.0.2.1", "sr:192.0.2.2")];
        let from = HashSet::from(["sr:192.0.2.1".to_string()]);
        let to = HashSet::from(["sr:198.51.100.1".to_string()]);
        assert_eq!(
            reachable_on_canonical(&edges, &from, &to),
            DownstreamFact::Disjoint
        );
    }

    #[test]
    fn empty_sets_are_disjoint() {
        let edges = [edge("sr:a", "sr:b")];
        assert_eq!(
            reachable_on_canonical(&edges, &HashSet::new(), &HashSet::from(["sr:b".into()])),
            DownstreamFact::Disjoint
        );
    }
}
