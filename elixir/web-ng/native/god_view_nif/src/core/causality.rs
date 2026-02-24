use crate::core::layout::MAX_BETWEENNESS_NODES;
use crate::types::causality::CausalStateReasonRow;
use deep_causality::{
    BaseCausaloid, CausableGraph, Causaloid, CausaloidGraph, IdentificationValue, NumericalValue,
    PropagatingEffect,
};
use std::collections::VecDeque;
use ultragraph::{CentralityGraphAlgorithms, GraphMut, UltraGraph};

pub fn betweenness_scores(node_count: usize, edges: &[(u32, u32)]) -> Option<Vec<f64>> {
    if node_count == 0 || node_count > MAX_BETWEENNESS_NODES {
        return None;
    }

    // Keep a mutable reference graph for continuous updates; clone for frozen analytics.
    let mut live_graph = UltraGraph::with_capacity(node_count, None);
    for idx in 0..node_count {
        let result = if idx == 0 {
            live_graph.add_root_node(idx)
        } else {
            live_graph.add_node(idx)
        };
        if result.is_err() {
            return None;
        }
    }

    for (source, target) in edges {
        let src = *source as usize;
        let dst = *target as usize;
        if src >= node_count || dst >= node_count || src == dst {
            continue;
        }

        if live_graph.add_edge(src, dst, ()).is_err() {
            return None;
        }
        if live_graph.add_edge(dst, src, ()).is_err() {
            return None;
        }
    }

    let mut analysis_graph = live_graph.clone();
    analysis_graph.freeze();

    let centrality = analysis_graph.betweenness_centrality(false, true).ok()?;
    let mut scores = vec![0.0_f64; node_count];
    for (idx, score) in centrality {
        if idx < scores.len() && score.is_finite() && score >= 0.0 {
            scores[idx] = score;
        }
    }

    Some(scores)
}

pub fn deep_causality_eval(obs: NumericalValue) -> PropagatingEffect<bool> {
    PropagatingEffect::pure(obs > 0.5)
}

pub fn evaluate_causal_states_with_reasons_impl(
    health_signals: Vec<u8>,
    edges: Vec<(u32, u32)>,
) -> Result<Vec<CausalStateReasonRow>, rustler::Error> {
    let node_count = health_signals.len();
    if node_count == 0 {
        return Ok(Vec::new());
    }

    let mut graph = CausaloidGraph::<BaseCausaloid<NumericalValue, bool>>::new(0);
    let mut node_indices = Vec::with_capacity(node_count);

    for idx in 0..node_count {
        let causaloid = Causaloid::new(
            idx as IdentificationValue,
            deep_causality_eval,
            "serviceradar_god_view_causal_eval",
        );

        let graph_index = if idx == 0 {
            graph
                .add_root_causaloid(causaloid)
                .map_err(|_| rustler::Error::BadArg)?
        } else {
            graph
                .add_causaloid(causaloid)
                .map_err(|_| rustler::Error::BadArg)?
        };
        node_indices.push(graph_index);
    }

    let mut adjacency = vec![Vec::<usize>::new(); node_count];
    let centrality_scores = betweenness_scores(node_count, &edges);

    for &(a, b) in &edges {
        let ai = a as usize;
        let bi = b as usize;

        if ai >= node_count || bi >= node_count || ai == bi {
            continue;
        }

        let ga = node_indices[ai];
        let gb = node_indices[bi];
        graph.add_edge(ga, gb).map_err(|_| rustler::Error::BadArg)?;
        graph.add_edge(gb, ga).map_err(|_| rustler::Error::BadArg)?;

        adjacency[ai].push(bi);
        adjacency[bi].push(ai);
    }
    graph.freeze();

    let unhealthy: Vec<usize> = health_signals
        .iter()
        .enumerate()
        .filter_map(|(idx, signal)| if *signal == 1 { Some(idx) } else { None })
        .collect();

    if unhealthy.is_empty() {
        return Ok(health_signals
            .iter()
            .map(|signal| {
                let state = if *signal == 0 { 2 } else { 3 };
                CausalStateReasonRow {
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
            .collect());
    }

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
        .ok_or(rustler::Error::BadArg)?;

    let mut dist = vec![usize::MAX; node_count];
    let mut parent = vec![usize::MAX; node_count];
    let mut queue = VecDeque::new();
    dist[root] = 0;
    queue.push_back(root);

    while let Some(current) = queue.pop_front() {
        let next_dist = dist[current] + 1;
        if next_dist > 3 {
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

    let mut out = Vec::with_capacity(node_count);

    for idx in 0..node_count {
        if idx == root {
            out.push(CausalStateReasonRow {
                state: 0,
                reason: "selected_as_root_from_unhealthy_candidates".to_string(),
                root_index: root as i64,
                parent_index: -1,
                hop_distance: 0,
            });
            continue;
        }

        if dist[idx] != usize::MAX && dist[idx] <= 3 {
            let parent_idx = if parent[idx] == usize::MAX {
                -1
            } else {
                parent[idx] as i64
            };

            out.push(CausalStateReasonRow {
                state: 1,
                reason: format!("reachable_from_root_within_{}_hops", dist[idx]),
                root_index: root as i64,
                parent_index: parent_idx,
                hop_distance: dist[idx] as i64,
            });
        } else if health_signals[idx] == 0 {
            out.push(CausalStateReasonRow {
                state: 2,
                reason: "healthy_signal_no_path_to_selected_root".to_string(),
                root_index: root as i64,
                parent_index: -1,
                hop_distance: -1,
            });
        } else {
            out.push(CausalStateReasonRow {
                state: 3,
                reason: "unhealthy_signal_not_reachable_from_selected_root".to_string(),
                root_index: root as i64,
                parent_index: -1,
                hop_distance: -1,
            });
        }
    }

    Ok(out)
}
