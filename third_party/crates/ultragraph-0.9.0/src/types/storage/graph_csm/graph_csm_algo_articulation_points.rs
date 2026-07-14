/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Articulation points (cut vertices) of the undirected view, via an iterative
//! Tarjan DFS. Operates on the symmetric adjacency built by
//! `graph_csm_biconnectivity_common::build_symmetric_adjacency`.
//!
//! Parent tracking uses edge **ids** (not vertex ids) so multi-edges and
//! symmetrization artifacts cannot be mistaken for back edges.

use crate::types::storage::graph_csm::graph_csm_biconnectivity_common::build_symmetric_adjacency;
use crate::{CsmGraph, GraphError, GraphView};

const NO_PARENT_EDGE: usize = usize::MAX;

pub(crate) fn articulation_points_impl<N, W>(g: &CsmGraph<N, W>) -> Result<Vec<usize>, GraphError>
where
    N: Clone,
    W: Clone + Default,
{
    let n = g.number_nodes();
    if n == 0 {
        return Ok(Vec::new());
    }

    let sym = build_symmetric_adjacency(g);

    let mut dfs_num: Vec<usize> = vec![usize::MAX; n];
    let mut low: Vec<usize> = vec![usize::MAX; n];
    let mut is_art: Vec<bool> = vec![false; n];
    let mut time: usize = 0;
    // Sentinel "no pending child" — must be outside [0, n).
    let no_child: usize = usize::MAX;

    // Frame: (u, next_edge_idx, parent_edge_id, child_count, last_child)
    let mut stack: Vec<(usize, usize, usize, usize, usize)> = Vec::new();

    for root in 0..n {
        if dfs_num[root] != usize::MAX {
            continue;
        }
        dfs_num[root] = time;
        low[root] = time;
        time += 1;
        stack.push((root, sym.offsets[root], NO_PARENT_EDGE, 0, no_child));

        while let Some(frame) = stack.last_mut() {
            // Post-process the most recently completed child, if any.
            if frame.4 != no_child {
                let u = frame.0;
                let c = frame.4;
                let lc = low[c];
                if lc < low[u] {
                    low[u] = lc;
                }
                if frame.2 != NO_PARENT_EDGE && lc >= dfs_num[u] {
                    is_art[u] = true;
                }
                frame.4 = no_child;
            }

            let u = frame.0;
            let end = sym.offsets[u + 1];

            if frame.1 >= end {
                // All neighbors processed: pop.
                let popped = *frame;
                stack.pop();
                if popped.2 == NO_PARENT_EDGE && popped.3 >= 2 {
                    // DFS root with two or more tree children.
                    is_art[popped.0] = true;
                }
                continue;
            }

            let idx = frame.1;
            frame.1 = idx + 1;
            let v = sym.targets[idx];
            let eid = sym.edge_ids[idx];

            if eid == frame.2 {
                // The edge by which we entered u — skip.
                continue;
            }

            if dfs_num[v] != usize::MAX {
                // Back edge.
                let dv = dfs_num[v];
                if dv < low[u] {
                    low[u] = dv;
                }
            } else {
                // Tree edge: descend into v.
                dfs_num[v] = time;
                low[v] = time;
                time += 1;
                frame.3 += 1;
                frame.4 = v;
                stack.push((v, sym.offsets[v], eid, 0, no_child));
            }
        }
    }

    let mut out: Vec<usize> = (0..n).filter(|&i| is_art[i]).collect();
    out.sort_unstable();
    out.dedup();
    Ok(out)
}
