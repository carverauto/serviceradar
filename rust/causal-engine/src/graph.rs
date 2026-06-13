//! Frozen-graph layer for the structural causaloids (C5/C5b/C9/C10).
//!
//! Projects the physical-topology view of [`Context`] (the `CONNECTS_TO` edges)
//! into a DeepCausality `CausaloidGraph`, freezes it into its optimized
//! ultragraph-backed representation, and exposes the structural / centrality /
//! reachability queries the graph causaloids need — mapping node indices back
//! to canonical `sr:` entity ids:
//!
//! - [`TopologyGraph::articulation_points`] — `StructuralGraphAlgorithms` (C5)
//! - [`TopologyGraph::bridges`] — `StructuralGraphAlgorithms` (C5b)
//! - [`TopologyGraph::betweenness`] — `CentralityGraphAlgorithms` (C9)
//! - [`TopologyGraph::reachable_from`] — `PathfindingGraphAlgorithms` (C10)
//!
//! Gap G (the algorithms) is already upstream through DeepCausality's
//! ultragraph-backed graph. `CONNECTS_TO` is undirected, which matches the
//! articulation-point / bridge semantics; management/containment edges are not
//! part of this reachability fabric.

use std::collections::{HashMap, HashSet};

use deep_causality::{
    CausableGraph, Causaloid, CausaloidGraph, MonadicCausableGraphReasoning, PropagatingEffect,
};
use ultragraph::{
    CentralityGraphAlgorithms, PathfindingGraphAlgorithms, StructuralGraphAlgorithms,
};

use crate::domain_model::{Context, EdgeKind, EntityId};

type TopologyCausaloid = Causaloid<bool, bool, (), ()>;

fn topology_signal(signal: bool) -> PropagatingEffect<bool> {
    PropagatingEffect::pure(signal)
}

/// A frozen physical-topology graph keyed back to canonical entity ids. Node
/// payload and edge weight are both `()` — structure is all the graph causaloids
/// need; the canonical ids live in the side maps.
pub struct TopologyGraph {
    graph: CausaloidGraph<TopologyCausaloid>,
    index_of: HashMap<EntityId, usize>,
    ids: Vec<EntityId>,
}

/// Intern an entity id, returning its dense node index (assigned in insertion
/// order, matching the order nodes are added to the graph).
fn intern(id: &str, ids: &mut Vec<EntityId>, index_of: &mut HashMap<EntityId, usize>) -> usize {
    if let Some(&i) = index_of.get(id) {
        return i;
    }
    let i = ids.len();
    ids.push(id.to_string());
    index_of.insert(id.to_string(), i);
    i
}

impl TopologyGraph {
    /// Build and freeze an undirected topology graph from the `CONNECTS_TO`
    /// edges of `ctx`. Returns `None` when there are no such edges (nothing to
    /// analyze) so the graph causaloids no-op cleanly.
    pub fn from_connects_to(ctx: &Context) -> Option<Self> {
        let mut ids: Vec<EntityId> = Vec::new();
        let mut index_of: HashMap<EntityId, usize> = HashMap::new();
        let mut links: Vec<(usize, usize)> = Vec::new();

        for edge in &ctx.edges {
            if edge.kind != EdgeKind::ConnectsTo {
                continue;
            }
            let a = intern(&edge.src, &mut ids, &mut index_of);
            let b = intern(&edge.dst, &mut ids, &mut index_of);
            links.push((a, b));
        }
        if links.is_empty() {
            return None;
        }

        let mut graph: CausaloidGraph<TopologyCausaloid> =
            CausaloidGraph::new_with_capacity(0, ids.len().max(1));
        // Nodes are added in 0..ids.len() order, so `add_node` assigns index i
        // to ids[i] — the same indices `intern` handed out for the edge list.
        for (index, id) in ids.iter().enumerate() {
            let causaloid = Causaloid::new(index as u64, topology_signal, id.as_str());

            if index == 0 {
                graph.add_root_causaloid(causaloid).ok()?;
            } else {
                graph.add_causaloid(causaloid).ok()?;
            }
        }
        for (a, b) in links {
            // Undirected: add both directions so reachability/centrality treat
            // the physical link symmetrically.
            graph.add_edg_with_weight(a, b, 1).ok()?;
            graph.add_edg_with_weight(b, a, 1).ok()?;
        }
        graph.freeze();

        Some(Self {
            graph,
            index_of,
            ids,
        })
    }

    fn id_at(&self, index: usize) -> Option<EntityId> {
        self.ids.get(index).cloned()
    }

    /// Articulation points: nodes whose removal partitions reachability (C5).
    pub fn articulation_points(&self) -> Vec<EntityId> {
        self.graph
            .get_graph()
            .articulation_points()
            .map(|indices| indices.into_iter().filter_map(|i| self.id_at(i)).collect())
            .unwrap_or_default()
    }

    /// Bridge edges: links whose removal partitions reachability (C5b). The
    /// undirected graph is stored bidirectionally, so each bridge is normalized
    /// and de-duplicated to a single unordered endpoint pair.
    pub fn bridges(&self) -> Vec<(EntityId, EntityId)> {
        let raw = match self.graph.get_graph().bridges() {
            Ok(b) => b,
            Err(_) => return Vec::new(),
        };
        let mut seen: HashSet<(usize, usize)> = HashSet::new();
        let mut out = Vec::new();
        for (a, b) in raw {
            let key = if a <= b { (a, b) } else { (b, a) };
            if !seen.insert(key) {
                continue;
            }
            if let (Some(sa), Some(sb)) = (self.id_at(key.0), self.id_at(key.1)) {
                out.push((sa, sb));
            }
        }
        out
    }

    /// Normalized betweenness centrality for every node (C9). Higher score => a
    /// shared hop more paths traverse.
    pub fn betweenness(&self) -> Vec<(EntityId, f64)> {
        self.graph
            .get_graph()
            .betweenness_centrality(false, true)
            .map(|scores| {
                scores
                    .into_iter()
                    .filter_map(|(i, s)| self.id_at(i).map(|id| (id, s)))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Canonical ids reachable from `source` (excluding itself) — the blast
    /// radius of a traffic source (C10).
    pub fn reachable_from(&self, source: &str) -> Vec<EntityId> {
        let Some(&start) = self.index_of.get(source) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for index in 0..self.ids.len() {
            if index == start {
                continue;
            }
            if self
                .graph
                .get_graph()
                .is_reachable(start, index)
                .unwrap_or(false)
                && let Some(id) = self.id_at(index)
            {
                out.push(id);
            }
        }
        out
    }

    /// Run a real DeepCausality graph traversal over the frozen topology.
    /// Structural C5/C5b/C9/C10 still use graph algorithms, but this gives the
    /// causal engine a direct monadic graph path for model-level checks.
    pub fn evaluate_signal_from(&self, source: &str, signal: bool) -> Option<bool> {
        let start = *self.index_of.get(source)?;
        let effect = self
            .graph
            .evaluate_subgraph_from_cause(start, &PropagatingEffect::pure(signal));

        if effect.is_err() {
            None
        } else {
            effect.value.into_value()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain_model::TopologyEdge;

    fn connects(a: &str, b: &str) -> TopologyEdge {
        TopologyEdge::new(a, b, EdgeKind::ConnectsTo)
    }

    /// A line graph a - b - c: `b` is the articulation point, both edges are
    /// bridges, and `b` has the highest betweenness.
    fn line_graph() -> Context {
        Context {
            edges: vec![connects("a", "b"), connects("b", "c")],
            ..Default::default()
        }
    }

    #[test]
    fn returns_none_without_connects_to_edges() {
        let ctx = Context {
            edges: vec![TopologyEdge::new("a", "b", EdgeKind::ManagedBy)],
            ..Default::default()
        };
        assert!(TopologyGraph::from_connects_to(&ctx).is_none());
    }

    #[test]
    fn finds_articulation_point_in_a_line() {
        let g = TopologyGraph::from_connects_to(&line_graph()).expect("graph");
        let aps = g.articulation_points();
        assert!(
            aps.contains(&"b".to_string()),
            "b should be articulation: {aps:?}"
        );
        assert!(!aps.contains(&"a".to_string()));
    }

    #[test]
    fn finds_bridges_in_a_line() {
        let g = TopologyGraph::from_connects_to(&line_graph()).expect("graph");
        let bridges = g.bridges();
        // Two undirected bridges (a-b, b-c), de-duplicated.
        assert_eq!(bridges.len(), 2, "bridges: {bridges:?}");
    }

    #[test]
    fn center_has_highest_betweenness() {
        let g = TopologyGraph::from_connects_to(&line_graph()).expect("graph");
        let scores = g.betweenness();
        let b = scores
            .iter()
            .find(|(id, _)| id == "b")
            .map(|(_, s)| *s)
            .unwrap();
        let a = scores
            .iter()
            .find(|(id, _)| id == "a")
            .map(|(_, s)| *s)
            .unwrap();
        assert!(b > a, "b ({b}) should exceed a ({a})");
    }

    #[test]
    fn reachable_from_spans_the_component() {
        let g = TopologyGraph::from_connects_to(&line_graph()).expect("graph");
        let mut reach = g.reachable_from("a");
        reach.sort();
        assert_eq!(reach, vec!["b".to_string(), "c".to_string()]);
    }

    #[test]
    fn evaluates_frozen_deep_causality_graph_from_source() {
        let g = TopologyGraph::from_connects_to(&line_graph()).expect("graph");

        assert_eq!(g.evaluate_signal_from("a", true), Some(true));
        assert_eq!(g.evaluate_signal_from("a", false), Some(false));
        assert_eq!(g.evaluate_signal_from("missing", true), None);
    }
}
