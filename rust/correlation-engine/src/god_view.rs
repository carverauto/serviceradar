//! God-View correlation-state extraction (task 1.10 step 1).
//!
//! The reasoning that previously lived in the web-ng `god_view_nif`
//! (`native/god_view_nif/src/core/causality.rs`) — betweenness-weighted
//! root-cause selection plus a 3-hop affected-cascade BFS — moves here so the
//! engine, not a render-time NIF, owns the rule + dependency reasoning. The dead DeepCausality
//! `CausaloidGraph` the NIF built-then-froze-but-never-queried is dropped; the
//! real logic is the centrality + BFS below.
//!
//! State codes match the NIF's `CausalStateReasonRow` (0=root, 1=affected,
//! 2=healthy, 3=unknown) and the reason strings are preserved verbatim, so the
//! shadow-mode diff (task 1.10.5) against the legacy NIF is exact.
//!
//! NIF cutover (steps 1.10.2–1.10.6) is deploy-gated — see
//! `openspec/changes/add-causal-engine/runbooks/god-view-nif-cutover.md`.

use std::collections::VecDeque;

use ultragraph::{CentralityGraphAlgorithms, GraphMut, UltraGraph};

use crate::reasoner::Classification;

/// Upper bound on nodes for the betweenness pass (mirrors the NIF's cap).
const MAX_BETWEENNESS_NODES: usize = 4_096;

/// Affected-cascade hop cap from the selected root (mirrors the NIF's BFS).
const MAX_AFFECTED_HOPS: usize = 3;

/// A single node's verdict in the God-View 4-bucket model.
#[derive(Debug, Clone, PartialEq)]
pub struct CorrelationStateRow {
    /// Encoded state: 0=root, 1=affected, 2=healthy, 3=unknown.
    pub state: u8,
    /// Programmatic reason the state was assigned.
    pub reason: String,
    /// Index of the selected root failure, or -1.
    pub root_index: i64,
    /// Nearest parent toward the root, or -1.
    pub parent_index: i64,
    /// Hop distance to the root, or -1.
    pub hop_distance: i64,
}

impl CorrelationStateRow {
    /// Map the encoded state to the engine [`Classification`].
    pub fn classification(&self) -> Classification {
        match self.state {
            0 => Classification::RootCause,
            1 => Classification::Affected,
            2 => Classification::Healthy,
            _ => Classification::Unknown,
        }
    }
}

/// Normalized betweenness centrality per node index, or `None` when the graph is
/// empty or exceeds [`MAX_BETWEENNESS_NODES`].
fn betweenness_scores(node_count: usize, edges: &[(u32, u32)]) -> Option<Vec<f64>> {
    if node_count == 0 || node_count > MAX_BETWEENNESS_NODES {
        return None;
    }

    let mut graph: UltraGraph<usize> = UltraGraph::with_capacity(node_count, None);
    for idx in 0..node_count {
        let result = if idx == 0 {
            graph.add_root_node(idx)
        } else {
            graph.add_node(idx)
        };
        result.ok()?;
    }
    for (source, target) in edges {
        let src = *source as usize;
        let dst = *target as usize;
        if src >= node_count || dst >= node_count || src == dst {
            continue;
        }
        graph.add_edge(src, dst, ()).ok()?;
        graph.add_edge(dst, src, ()).ok()?;
    }
    graph.freeze();

    let centrality = graph.betweenness_centrality(false, true).ok()?;
    let mut scores = vec![0.0_f64; node_count];
    for (idx, score) in centrality {
        if idx < scores.len() && score.is_finite() && score >= 0.0 {
            scores[idx] = score;
        }
    }
    Some(scores)
}

/// Evaluate per-node correlation states from boolean health signals (0=OK, 1=FAIL)
/// over an undirected edge list. Identical in behavior to the former NIF
/// `evaluate_causal_states_with_reasons_impl`.
pub fn evaluate_correlation_states(
    health_signals: &[u8],
    edges: &[(u32, u32)],
) -> Vec<CorrelationStateRow> {
    let node_count = health_signals.len();
    if node_count == 0 {
        return Vec::new();
    }

    let mut adjacency = vec![Vec::<usize>::new(); node_count];
    let centrality_scores = betweenness_scores(node_count, edges);
    for &(a, b) in edges {
        let ai = a as usize;
        let bi = b as usize;
        if ai >= node_count || bi >= node_count || ai == bi {
            continue;
        }
        adjacency[ai].push(bi);
        adjacency[bi].push(ai);
    }

    let unhealthy: Vec<usize> = health_signals
        .iter()
        .enumerate()
        .filter_map(|(idx, signal)| if *signal == 1 { Some(idx) } else { None })
        .collect();

    if unhealthy.is_empty() {
        return health_signals
            .iter()
            .map(|signal| {
                let state = if *signal == 0 { 2 } else { 3 };
                CorrelationStateRow {
                    state,
                    reason: if state == 2 {
                        "healthy_signal_no_detected_causal_impact".to_string()
                    } else {
                        "unknown_signal_without_identified_root".to_string()
                    },
                    root_index: -1,
                    parent_index: -1,
                    hop_distance: -1,
                }
            })
            .collect();
    }

    // Highest-centrality unhealthy node wins; ties broken by degree, then lowest
    // index (matches the NIF's max_by_key ordering exactly).
    let root = unhealthy
        .iter()
        .copied()
        .max_by_key(|idx| {
            let centrality = centrality_scores
                .as_ref()
                .and_then(|scores| scores.get(*idx))
                .copied()
                .unwrap_or(0.0);
            let scaled = (centrality * 1_000_000.0).round() as i64;
            (scaled, adjacency[*idx].len() as i64, -(*idx as i64))
        })
        .expect("unhealthy is non-empty");

    let mut dist = vec![usize::MAX; node_count];
    let mut parent = vec![usize::MAX; node_count];
    let mut queue = VecDeque::new();
    dist[root] = 0;
    queue.push_back(root);
    while let Some(current) = queue.pop_front() {
        let next_dist = dist[current] + 1;
        if next_dist > MAX_AFFECTED_HOPS {
            continue;
        }
        for neighbor in &adjacency[current] {
            if dist[*neighbor] == usize::MAX {
                dist[*neighbor] = next_dist;
                parent[*neighbor] = current;
                queue.push_back(*neighbor);
            }
        }
    }

    (0..node_count)
        .map(|idx| {
            if idx == root {
                return CorrelationStateRow {
                    state: 0,
                    reason: "selected_as_root_from_unhealthy_candidates".to_string(),
                    root_index: root as i64,
                    parent_index: -1,
                    hop_distance: 0,
                };
            }
            if dist[idx] != usize::MAX && dist[idx] <= MAX_AFFECTED_HOPS {
                let parent_idx = if parent[idx] == usize::MAX {
                    -1
                } else {
                    parent[idx] as i64
                };
                CorrelationStateRow {
                    state: 1,
                    reason: format!("reachable_from_root_within_{}_hops", dist[idx]),
                    root_index: root as i64,
                    parent_index: parent_idx,
                    hop_distance: dist[idx] as i64,
                }
            } else if health_signals[idx] == 0 {
                CorrelationStateRow {
                    state: 2,
                    reason: "healthy_signal_no_path_to_selected_root".to_string(),
                    root_index: root as i64,
                    parent_index: -1,
                    hop_distance: -1,
                }
            } else {
                CorrelationStateRow {
                    state: 3,
                    reason: "unhealthy_signal_not_reachable_from_selected_root".to_string(),
                    root_index: root as i64,
                    parent_index: -1,
                    hop_distance: -1,
                }
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_signals_yield_no_rows() {
        assert!(evaluate_correlation_states(&[], &[]).is_empty());
    }

    #[test]
    fn all_healthy_when_no_failures() {
        let rows = evaluate_correlation_states(&[0, 0, 0], &[(0, 1), (1, 2)]);
        assert!(rows.iter().all(|r| r.state == 2));
        assert!(rows.iter().all(|r| r.root_index == -1));
    }

    #[test]
    fn single_failure_is_root_and_neighbors_are_affected() {
        // line 0-1-2; node 1 fails
        let rows = evaluate_correlation_states(&[0, 1, 0], &[(0, 1), (1, 2)]);
        assert_eq!(rows[1].state, 0); // root
        assert_eq!(rows[0].state, 1); // affected within 1 hop
        assert_eq!(rows[2].state, 1);
        assert_eq!(rows[0].hop_distance, 1);
    }

    #[test]
    fn most_central_unhealthy_node_is_selected_root() {
        // hub 0 wired to 1,2,3 with 1-4 tail; nodes 0 and 4 both fail. The hub is
        // far more central, so it is chosen as the root over the leaf.
        let rows = evaluate_correlation_states(&[1, 0, 0, 0, 1], &[(0, 1), (0, 2), (0, 3), (1, 4)]);
        assert_eq!(rows[0].state, 0);
        assert_eq!(rows[0].classification(), Classification::RootCause);
    }

    #[test]
    fn unhealthy_node_unreachable_from_root_is_unknown() {
        // edge only 0-1; nodes 0 and 2 fail. Root is 0 (more connected); node 2
        // is unhealthy but unreachable => unknown(3); node 3 is healthy and
        // unreachable => healthy(2).
        let rows = evaluate_correlation_states(&[1, 0, 1, 0], &[(0, 1)]);
        assert_eq!(rows[0].state, 0);
        assert_eq!(rows[2].state, 3);
        assert_eq!(rows[2].classification(), Classification::Unknown);
        assert_eq!(rows[3].state, 2);
    }
}
