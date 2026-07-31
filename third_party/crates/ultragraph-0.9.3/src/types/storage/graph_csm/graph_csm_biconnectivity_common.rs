/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Shared undirected-view adjacency used by the three biconnectivity algorithms
//! (`articulation_points`, `bridges`, `biconnected_components`).
//!
//! The three algorithms are defined on undirected graphs. `CsmGraph` stores
//! directed adjacency. This helper materializes a symmetric CSR view: every
//! distinct undirected edge `{u, v}` (with `u != v`) is represented as two
//! half-edges that share a stable `edge_id`. The shared id is what lets the
//! DFS distinguish "the edge we arrived on" from a real back edge — robust
//! to multi-edges in the input.
//!
//! Self-loops are discarded. Reverse-orientation duplicates (one undirected
//! edge stored as both `u -> v` and `v -> u`) coalesce into a single undirected
//! edge. Genuine parallel multi-edges (the same direction stored more than
//! once) are preserved with their multiplicity; collapsing them would turn a
//! multigraph into a simple graph and yield wrong bridges/biconnected
//! components (e.g., two parallel edges between `u` and `v` are not a bridge,
//! but a collapsed single edge would be).

use crate::{CsmGraph, GraphView};
use std::collections::HashMap;

/// Symmetric CSR adjacency over the undirected view of a `CsmGraph`.
///
/// - `offsets` has length `V + 1`; `offsets[v]..offsets[v+1]` slices the
///   half-edges incident to vertex `v`.
/// - `targets[i]` is the neighbor reached by half-edge `i`.
/// - `edge_ids[i]` is the canonical id `0..num_edges` of the undirected
///   edge containing half-edge `i`; the two paired half-edges share the id.
///
/// The count of distinct undirected edges is `targets.len() / 2`.
pub(crate) struct SymmetricAdjacency {
    pub(crate) offsets: Vec<usize>,
    pub(crate) targets: Vec<usize>,
    pub(crate) edge_ids: Vec<usize>,
}

pub(crate) fn build_symmetric_adjacency<N, W>(g: &CsmGraph<N, W>) -> SymmetricAdjacency
where
    N: Clone,
    W: Clone + Default,
{
    let n = g.number_nodes();

    // Count occurrences of each ordered direction for every canonical pair
    // (a, b) with a < b. The undirected multiplicity is then max(forward,
    // reverse): each reverse-orientation storage pairs with one forward to
    // represent a single undirected edge; any unpaired forwards or reverses
    // are genuine parallel multi-edges. This rule is consistent with
    // `parallel_directed_edges_canonicalized_to_min_max` (anti-parallel pair
    // -> one undirected edge) and preserves multigraph semantics.
    let mut counts: HashMap<(usize, usize), (usize, usize)> = HashMap::new();
    for u in 0..n {
        let start = g.forward_edges.offsets[u];
        let end = g.forward_edges.offsets[u + 1];
        for &v in &g.forward_edges.targets[start..end] {
            if u == v {
                continue;
            }
            let (a, b, is_forward) = if u < v { (u, v, true) } else { (v, u, false) };
            let entry = counts.entry((a, b)).or_insert((0usize, 0usize));
            if is_forward {
                entry.0 += 1;
            } else {
                entry.1 += 1;
            }
        }
    }

    // Expand each canonical pair into `max(forward, reverse)` distinct
    // undirected edges. Each occurrence below receives its own `edge_id`,
    // which is what lets the Tarjan DFS distinguish "the edge we arrived
    // on" from a parallel sibling edge.
    let mut canonical: Vec<(usize, usize)> = Vec::new();
    for (&(a, b), &(f, r)) in counts.iter() {
        let m = f.max(r);
        for _ in 0..m {
            canonical.push((a, b));
        }
    }
    // Sort to make edge_id assignment deterministic regardless of CSR layout.
    canonical.sort_unstable();

    let mut degree: Vec<usize> = vec![0; n];
    for &(a, b) in &canonical {
        degree[a] += 1;
        degree[b] += 1;
    }

    let mut offsets: Vec<usize> = vec![0; n + 1];
    for i in 0..n {
        offsets[i + 1] = offsets[i] + degree[i];
    }
    let total = offsets[n];

    let mut targets: Vec<usize> = vec![0; total];
    let mut edge_ids: Vec<usize> = vec![0; total];
    let mut cursor: Vec<usize> = offsets[..n].to_vec();

    for (id, &(a, b)) in canonical.iter().enumerate() {
        let pa = cursor[a];
        cursor[a] += 1;
        targets[pa] = b;
        edge_ids[pa] = id;

        let pb = cursor[b];
        cursor[b] += 1;
        targets[pb] = a;
        edge_ids[pb] = id;
    }

    SymmetricAdjacency {
        offsets,
        targets,
        edge_ids,
    }
}

// Coverage of this helper is delivered by the integration tests of the
// three biconnectivity algorithms (see ultragraph/tests/...). All branches
// of `build_symmetric_adjacency` are exercised by their fixtures:
// empty graph, isolated vertices, self-loops, single directed edge,
// both directions stored, multi-edges, mixed.
