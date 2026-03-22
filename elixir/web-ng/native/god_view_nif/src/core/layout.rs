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
    edges: &[(u16, u16, u32, u64, u64, String, u8)],
) -> HypergraphProjection {
    let mut projection = HypergraphProjection {
        num_nodes,
        ..Default::default()
    };

    if num_nodes == 0 || edges.is_empty() {
        return projection;
    }

    projection.incidence_triplets.reserve(edges.len() * 2);

    for (source, target, _, _, _, _, _) in edges {
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

fn reorder_layer_by_barycenter(
    layers: &mut [Vec<usize>],
    layer_idx: usize,
    reference_idx: usize,
    adjacency: &[Vec<usize>],
    layer_of: &[usize],
) {
    let current = layers.get(layer_idx).cloned().unwrap_or_default();
    let reference = layers.get(reference_idx).cloned().unwrap_or_default();
    if current.len() <= 1 || reference.is_empty() {
        return;
    }

    let mut reference_pos = vec![usize::MAX; layer_of.len()];
    for (order, node) in reference.iter().copied().enumerate() {
        if node < reference_pos.len() {
            reference_pos[node] = order;
        }
    }

    let mut ranked = current
        .iter()
        .copied()
        .enumerate()
        .map(|(order, node)| {
            let mut sum = 0.0_f64;
            let mut count = 0usize;

            for &neighbor in &adjacency[node] {
                if layer_of.get(neighbor).copied() == Some(reference_idx)
                    && reference_pos[neighbor] != usize::MAX
                {
                    sum += reference_pos[neighbor] as f64;
                    count += 1;
                }
            }

            let barycenter = if count == 0 {
                f64::INFINITY
            } else {
                sum / count as f64
            };

            (node, barycenter, order)
        })
        .collect::<Vec<_>>();

    ranked.sort_by(|a, b| {
        a.1.total_cmp(&b.1)
            .then_with(|| a.2.cmp(&b.2))
            .then_with(|| a.0.cmp(&b.0))
    });

    layers[layer_idx] = ranked.into_iter().map(|(node, _, _)| node).collect();
}

fn count_crossings_between_layers(
    left: &[usize],
    right: &[usize],
    adjacency: &[Vec<usize>],
    layer_of: &[usize],
    right_layer_idx: usize,
) -> usize {
    if left.len() <= 1 || right.len() <= 1 {
        return 0;
    }

    let mut left_pos = vec![usize::MAX; layer_of.len()];
    let mut right_pos = vec![usize::MAX; layer_of.len()];

    for (order, node) in left.iter().copied().enumerate() {
        if node < left_pos.len() {
            left_pos[node] = order;
        }
    }

    for (order, node) in right.iter().copied().enumerate() {
        if node < right_pos.len() {
            right_pos[node] = order;
        }
    }

    let mut segments = Vec::<(usize, usize)>::new();
    for &source in left {
        let source_pos = left_pos[source];
        for &target in &adjacency[source] {
            if layer_of.get(target).copied() == Some(right_layer_idx)
                && right_pos[target] != usize::MAX
                && source_pos != usize::MAX
            {
                segments.push((source_pos, right_pos[target]));
            }
        }
    }

    let mut crossings = 0usize;
    for i in 0..segments.len() {
        for j in (i + 1)..segments.len() {
            let (a_left, a_right) = segments[i];
            let (b_left, b_right) = segments[j];
            if a_left == b_left || a_right == b_right {
                continue;
            }
            if (a_left < b_left && a_right > b_right) || (a_left > b_left && a_right < b_right) {
                crossings += 1;
            }
        }
    }

    crossings
}

fn total_crossings(layers: &[Vec<usize>], adjacency: &[Vec<usize>], layer_of: &[usize]) -> usize {
    if layers.len() <= 1 {
        return 0;
    }

    let mut total = 0usize;
    for idx in 0..(layers.len() - 1) {
        total += count_crossings_between_layers(
            &layers[idx],
            &layers[idx + 1],
            adjacency,
            layer_of,
            idx + 1,
        );
    }
    total
}

fn transpose_pass(layers: &mut [Vec<usize>], adjacency: &[Vec<usize>], layer_of: &[usize]) {
    if layers.len() <= 1 {
        return;
    }

    let mut improved = true;
    while improved {
        improved = false;

        for layer_idx in 0..layers.len() {
            if layers[layer_idx].len() <= 1 {
                continue;
            }

            let mut pos = 0usize;
            while pos + 1 < layers[layer_idx].len() {
                let before = local_crossings(layers, adjacency, layer_of, layer_idx);
                layers[layer_idx].swap(pos, pos + 1);
                let after = local_crossings(layers, adjacency, layer_of, layer_idx);

                if after < before {
                    improved = true;
                    pos += 1;
                } else {
                    layers[layer_idx].swap(pos, pos + 1);
                    pos += 1;
                }
            }
        }
    }
}

fn local_crossings(
    layers: &[Vec<usize>],
    adjacency: &[Vec<usize>],
    layer_of: &[usize],
    layer_idx: usize,
) -> usize {
    let mut total = 0usize;

    if layer_idx > 0 {
        total += count_crossings_between_layers(
            &layers[layer_idx - 1],
            &layers[layer_idx],
            adjacency,
            layer_of,
            layer_idx,
        );
    }

    if layer_idx + 1 < layers.len() {
        total += count_crossings_between_layers(
            &layers[layer_idx],
            &layers[layer_idx + 1],
            adjacency,
            layer_of,
            layer_idx + 1,
        );
    }

    total
}

fn reduce_crossings(layers: &mut [Vec<usize>], adjacency: &[Vec<usize>], layer_of: &[usize]) {
    if layers.len() <= 1 {
        return;
    }

    let mut best_layers = layers.to_vec();
    let mut best_crossings = total_crossings(layers, adjacency, layer_of);
    if best_crossings == 0 {
        return;
    }

    for _ in 0..12 {
        for layer_idx in 1..layers.len() {
            reorder_layer_by_barycenter(layers, layer_idx, layer_idx - 1, adjacency, layer_of);
        }

        for layer_idx in (0..(layers.len() - 1)).rev() {
            reorder_layer_by_barycenter(layers, layer_idx, layer_idx + 1, adjacency, layer_of);
        }

        transpose_pass(layers, adjacency, layer_of);

        let crossings = total_crossings(layers, adjacency, layer_of);
        if crossings < best_crossings {
            best_crossings = crossings;
            best_layers = layers.to_vec();
        }
        if best_crossings == 0 {
            break;
        }
    }

    layers.clone_from_slice(&best_layers);
}

/// Core topographical layout engine for constructing 2D network views.
///
/// Uses node weights and adjacency to intelligently anchor components and fan
/// out their leaf nodes via breadth-first tier discovery. The output is laid
/// out left-to-right so backbone paths read horizontally instead of vertically.
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
    let canvas_top = 40.0_f64;
    let min_sep = 24.0_f64;
    let max_component_size = components.iter().map(|c| c.len()).max().unwrap_or(1) as f64;
    let canvas_bottom = (canvas_top + (max_component_size * min_sep * 2.0).max(240.0)).min(65000.0);
    let layer_gap = 108.0_f64;

    for (comp_idx, component) in components.iter().enumerate() {
        let mut in_component = vec![false; count];
        for &node in component {
            in_component[node] = true;
        }

        let slot = (comp_idx as f64 + 0.5) / comp_total;
        let comp_center_y = canvas_top + (canvas_bottom - canvas_top) * slot;
        let comp_span = ((canvas_bottom - canvas_top) / comp_total * 0.92).max(88.0);
        let comp_min_y = (comp_center_y - comp_span / 2.0).max(canvas_top);
        let comp_max_y = (comp_center_y + comp_span / 2.0).min(canvas_bottom);

        if component.len() == 1 {
            let node = component[0];
            positions[node] = (canvas_left.round() as u16, comp_center_y.round() as u16);
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

        let max_level = levels.last().copied().unwrap_or(0);
        let mut layer_of = vec![usize::MAX; count];
        for (&node, &layer_idx) in &level {
            if node < layer_of.len() {
                layer_of[node] = layer_idx;
            }
        }

        let mut ordered_layers = vec![Vec::<usize>::new(); max_level + 1];
        for l in levels.iter().copied() {
            let mut nodes = by_level.remove(&l).unwrap_or_default();
            nodes.sort_unstable();
            ordered_layers[l] = nodes;
        }

        reduce_crossings(&mut ordered_layers, &adjacency, &layer_of);

        for l in levels {
            let nodes = ordered_layers.get(l).cloned().unwrap_or_default();

            if l == 0 && nodes.len() == 1 {
                let node = nodes[0];
                positions[node] = (canvas_left.round() as u16, comp_center_y.round() as u16);
                continue;
            }

            let x = canvas_left + l as f64 * layer_gap;

            let desired = nodes
                .iter()
                .map(|node| {
                    let mut parent_y = Vec::new();
                    for parent in &adjacency[*node] {
                        if in_component[*parent]
                            && level.get(parent).copied().unwrap_or(usize::MAX) + 1 == l
                        {
                            parent_y.push(positions[*parent].1 as f64);
                        }
                    }
                    parent_y.sort_by(|a, b| a.total_cmp(b));
                    let target = if parent_y.is_empty() {
                        comp_center_y
                    } else {
                        parent_y.iter().sum::<f64>() / parent_y.len() as f64
                    };
                    target
                })
                .collect::<Vec<_>>();

            let mut placed = Vec::<(usize, f64)>::new();
            let mut cursor = comp_min_y;
            for (idx, node) in nodes.iter().copied().enumerate() {
                let target = desired.get(idx).copied().unwrap_or(comp_center_y);
                let y = target.max(cursor).min(comp_max_y);
                placed.push((node, y));
                cursor = y + min_sep;
            }

            if let Some((_, last_y)) = placed.last().copied() {
                if last_y > comp_max_y {
                    let shift = last_y - comp_max_y;
                    for (_, y) in &mut placed {
                        *y = (*y - shift).max(comp_min_y);
                    }
                }
            }

            for (node, y) in placed {
                let x = x.round().clamp(0.0, 65535.0) as u16;
                let y = y.round().clamp(0.0, 65535.0) as u16;
                positions[node] = (x, y);
            }
        }
    }

    positions
}
