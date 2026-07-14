/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Bridges (cut edges) of the undirected view, via an iterative Tarjan DFS.
//! Parent tracking uses edge ids (see `graph_csm_biconnectivity_common`).

use crate::types::storage::graph_csm::graph_csm_biconnectivity_common::build_symmetric_adjacency;
use crate::{CsmGraph, GraphError, GraphView};

const NO_PARENT_EDGE: usize = usize::MAX;

pub(crate) fn bridges_impl<N, W>(g: &CsmGraph<N, W>) -> Result<Vec<(usize, usize)>, GraphError>
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
    let mut time: usize = 0;
    let no_child: usize = usize::MAX;

    let mut bridges: Vec<(usize, usize)> = Vec::new();

    // Frame: (u, next_edge_idx, parent_edge_id, last_child)
    let mut stack: Vec<(usize, usize, usize, usize)> = Vec::new();

    for root in 0..n {
        if dfs_num[root] != usize::MAX {
            continue;
        }
        dfs_num[root] = time;
        low[root] = time;
        time += 1;
        stack.push((root, sym.offsets[root], NO_PARENT_EDGE, no_child));

        while let Some(frame) = stack.last_mut() {
            if frame.3 != no_child {
                let u = frame.0;
                let c = frame.3;
                let lc = low[c];
                if lc < low[u] {
                    low[u] = lc;
                }
                if lc > dfs_num[u] {
                    let (a, b) = if u < c { (u, c) } else { (c, u) };
                    bridges.push((a, b));
                }
                frame.3 = no_child;
            }

            let u = frame.0;
            let end = sym.offsets[u + 1];

            if frame.1 >= end {
                stack.pop();
                continue;
            }

            let idx = frame.1;
            frame.1 = idx + 1;
            let v = sym.targets[idx];
            let eid = sym.edge_ids[idx];

            if eid == frame.2 {
                continue;
            }

            if dfs_num[v] != usize::MAX {
                let dv = dfs_num[v];
                if dv < low[u] {
                    low[u] = dv;
                }
            } else {
                dfs_num[v] = time;
                low[v] = time;
                time += 1;
                frame.3 = v;
                stack.push((v, sym.offsets[v], eid, no_child));
            }
        }
    }

    bridges.sort_unstable();
    Ok(bridges)
}
