//! Graph routing and spatial layout algorithms.
//!
//! Handles projecting logical structural data into optimal 2D X/Y components.
//! It isolates large connected network groups, organizes device anchors via weights
//! or breadth-first hop counts, and falls back to naive rings for disjoint systems.

use crate::types::hypergraph::HypergraphProjection;
use deep_causality_sparse::CsrMatrix;
use deep_causality_tensor::CausalTensor;
use deep_causality_topology::Hypergraph;
use std::collections::{HashMap, HashSet, VecDeque};

/// Safety restraint ensuring massive dense matrices don't OOM during centrality analytics.
pub(crate) const MAX_BETWEENNESS_NODES: usize = 4_096;

/// Maps a raw sequence of edges into a bounded mathematical Hypergraph instance bounds check bounds.
///
/// Returns a projection containing bounds stats and incidence mappings.
pub(crate) fn build_hypergraph_projection(
    num_nodes: usize,
    edges: &[(u16, u16, u32, u64, u64, String)],
) -> HypergraphProjection {
    let mut projection = HypergraphProjection {
        num_nodes,
        ..Default::default()
    };

    if num_nodes == 0 || edges.is_empty() {
        return projection;
    }

    projection.incidence_triplets.reserve(edges.len() * 2);

    for (source, target, _, _, _, _) in edges {
        let src = usize::from(*source);
        let dst = usize::from(*target);

        if src >= num_nodes || dst >= num_nodes {
            projection.dropped_edges += 1;
            continue;
        }

        let hidx = projection.num_hyperedges;
        projection.num_hyperedges += 1;
        projection.incidence_triplets.push((src, hidx, 1));
        if src != dst {
            projection.incidence_triplets.push((dst, hidx, 1));
        }
    }

    projection
}

/// Consumes a structurally-validated hypergraph projection and constructs the underlying `Hypergraph` instance.
pub(crate) fn build_hypergraph_from_projection(
    projection: &HypergraphProjection,
) -> Option<Hypergraph<f32>> {
    if projection.num_nodes == 0 || projection.num_hyperedges == 0 {
        return None;
    }

    let incidence = CsrMatrix::from_triplets(
        projection.num_nodes,
        projection.num_hyperedges,
        &projection.incidence_triplets,
    )
    .ok()?;

    let node_data = CausalTensor::new(
        vec![0.0_f32; projection.num_nodes],
        vec![projection.num_nodes],
    )
    .ok()?;
    Hypergraph::new(incidence, node_data, 0).ok()
}

/// Fallback visualizer engine mapping disjoint network components into a clean overlapping circle.
pub(crate) fn fallback_ring_layout(node_count: usize) -> Vec<(u16, u16)> {
    if node_count == 0 {
        return Vec::new();
    }

    let center_x = 320.0_f64;
    let center_y = 160.0_f64;
    let radius = 120.0 + (node_count as f64 * 0.8);
    let step = std::f64::consts::TAU / node_count as f64;

    (0..node_count)
        .map(|idx| {
            let angle = step * idx as f64;
            let x = center_x + radius * angle.cos();
            let y = center_y + radius * angle.sin();
            (
                x.round().clamp(0.0, 65535.0) as u16,
                y.round().clamp(0.0, 65535.0) as u16,
            )
        })
        .collect()
}

/// Validates raw integer links and outputs deterministic adjacency arrays for traversal algorithms.
pub(crate) fn build_adjacency_from_indexed_edges(
    node_count: usize,
    edges: &[(u32, u32)],
) -> Vec<Vec<usize>> {
    let mut adjacency = vec![HashSet::<usize>::new(); node_count];

    for (source, target) in edges {
        let src = *source as usize;
        let dst = *target as usize;
        if src >= node_count || dst >= node_count || src == dst {
            continue;
        }

        adjacency[src].insert(dst);
        adjacency[dst].insert(src);
    }

    adjacency
        .into_iter()
        .map(|neighbors| {
            let mut values: Vec<usize> = neighbors.into_iter().collect();
            values.sort_unstable();
            values
        })
        .collect()
}

/// Core topographical layout engine for constructing 2D network views.
///
/// Uses node weights and adjacency to intelligently anchor components and fan
/// out their leaf nodes via breadth-first tier discovery. Adjusts spatial overlaps
/// automatically horizontally.
pub(crate) fn layout_nodes_layered(
    node_count: usize,
    edges: &[(u32, u32)],
    node_weights: &[u32],
) -> Vec<(u16, u16)> {
    let count = node_count as usize;
    if count == 0 {
        return Vec::new();
    }

    let adjacency = build_adjacency_from_indexed_edges(count, edges);
    if adjacency.iter().all(|neighbors| neighbors.is_empty()) {
        return fallback_ring_layout(count);
    }

    let mut visited = vec![false; count];
    let mut components = Vec::<Vec<usize>>::new();

    for start in 0..count {
        if visited[start] {
            continue;
        }

        let mut queue = VecDeque::new();
        let mut component = Vec::new();
        queue.push_back(start);
        visited[start] = true;

        while let Some(node) = queue.pop_front() {
            component.push(node);
            for &next in &adjacency[node] {
                if !visited[next] {
                    visited[next] = true;
                    queue.push_back(next);
                }
            }
        }

        components.push(component);
    }

    components.sort_by(|a, b| {
        b.len()
            .cmp(&a.len())
            .then_with(|| a.iter().min().cmp(&b.iter().min()))
    });

    let mut positions = vec![(0u16, 0u16); count];
    let comp_total = components.len().max(1) as f64;
    let canvas_left = 40.0_f64;
    let canvas_right = 600.0_f64;
    let canvas_top = 48.0_f64;
    let layer_gap = 92.0_f64;

    for (comp_idx, component) in components.iter().enumerate() {
        let mut in_component = vec![false; count];
        for &node in component {
            in_component[node] = true;
        }

        let slot = (comp_idx as f64 + 0.5) / comp_total;
        let comp_center_x = canvas_left + (canvas_right - canvas_left) * slot;
        let comp_span = ((canvas_right - canvas_left) / comp_total * 0.92).max(120.0);
        let comp_min_x = (comp_center_x - comp_span / 2.0).max(canvas_left);
        let comp_max_x = (comp_center_x + comp_span / 2.0).min(canvas_right);

        if component.len() == 1 {
            let node = component[0];
            positions[node] = (comp_center_x.round() as u16, canvas_top.round() as u16);
            continue;
        }

        let weight_at = |idx: usize| -> u32 { *node_weights.get(idx).unwrap_or(&0) };
        let root = component
            .iter()
            .copied()
            .max_by_key(|n| (weight_at(*n), adjacency[*n].len(), usize::MAX - *n))
            .unwrap_or(component[0]);

        let mut level = HashMap::<usize, usize>::new();
        let mut queue = VecDeque::new();
        queue.push_back(root);
        level.insert(root, 0);

        while let Some(node) = queue.pop_front() {
            let curr = *level.get(&node).unwrap_or(&0);
            for &next in &adjacency[node] {
                if in_component[next] && !level.contains_key(&next) {
                    level.insert(next, curr + 1);
                    queue.push_back(next);
                }
            }
        }

        let mut by_level = HashMap::<usize, Vec<usize>>::new();
        for &node in component {
            let l = *level.get(&node).unwrap_or(&0);
            by_level.entry(l).or_default().push(node);
        }

        let mut levels: Vec<usize> = by_level.keys().copied().collect();
        levels.sort_unstable();

        for l in levels {
            let mut nodes = by_level.remove(&l).unwrap_or_default();
            nodes.sort_unstable();

            if l == 0 && nodes.len() == 1 {
                let node = nodes[0];
                positions[node] = (comp_center_x.round() as u16, canvas_top.round() as u16);
                continue;
            }

            let y = canvas_top + l as f64 * layer_gap;
            let min_sep = 24.0_f64;

            let mut desired = nodes
                .iter()
                .map(|node| {
                    let mut parent_x = Vec::new();
                    for parent in &adjacency[*node] {
                        if in_component[*parent]
                            && level.get(parent).copied().unwrap_or(usize::MAX) + 1 == l
                        {
                            parent_x.push(positions[*parent].0 as f64);
                        }
                    }
                    parent_x.sort_by(|a, b| a.total_cmp(b));
                    let target = if parent_x.is_empty() {
                        comp_center_x
                    } else {
                        parent_x.iter().sum::<f64>() / parent_x.len() as f64
                    };
                    (*node, target)
                })
                .collect::<Vec<_>>();

            desired.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.cmp(&b.0)));

            let mut placed = Vec::<(usize, f64)>::new();
            let mut cursor = comp_min_x;
            for (node, target) in desired {
                let x = target.max(cursor).min(comp_max_x);
                placed.push((node, x));
                cursor = x + min_sep;
            }

            if let Some((_, last_x)) = placed.last().copied() {
                if last_x > comp_max_x {
                    let shift = last_x - comp_max_x;
                    for (_, x) in &mut placed {
                        *x = (*x - shift).max(comp_min_x);
                    }
                }
            }

            for (node, x) in placed {
                let x = x.round().clamp(0.0, 65535.0) as u16;
                let y = y.round().clamp(0.0, 65535.0) as u16;
                positions[node] = (x, y);
            }
        }
    }

    positions
}
