/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Biconnected components of the undirected view, via Tarjan's edge-stack
//! variant of the DFS. Each undirected edge is pushed exactly once (only
//! from the side whose endpoint has the larger dfs_num); when an articulation
//! condition fires for tree edge (u, v), all edges back to that tree edge
//! form one biconnected component.

use crate::types::storage::graph_csm::graph_csm_biconnectivity_common::build_symmetric_adjacency;
use crate::{CsmGraph, GraphError, GraphView};

const NO_PARENT_EDGE: usize = usize::MAX;

pub(crate) fn biconnected_components_impl<N, W>(
    g: &CsmGraph<N, W>,
) -> Result<Vec<Vec<usize>>, GraphError>
where
    N: Clone,
    W: Clone + Default,
{
    let n = g.number_nodes();
    if n == 0 {
        return Ok(Vec::new());
    }

    let sym = build_symmetric_adjacency(g);
    let num_edges = sym.targets.len() / 2;

    // edge_id -> canonical (min, max) endpoints.
    let mut endpoints: Vec<(usize, usize)> = vec![(0, 0); num_edges];
    for u in 0..n {
        for idx in sym.offsets[u]..sym.offsets[u + 1] {
            let v = sym.targets[idx];
            if u < v {
                endpoints[sym.edge_ids[idx]] = (u, v);
            }
        }
    }

    let mut dfs_num: Vec<usize> = vec![usize::MAX; n];
    let mut low: Vec<usize> = vec![usize::MAX; n];
    let mut time: usize = 0;
    let no_child: usize = usize::MAX;

    let mut edge_stack: Vec<usize> = Vec::new();
    let mut components: Vec<Vec<usize>> = Vec::new();

    // Frame: (u, next_edge_idx, parent_edge_id, last_child, tree_edge_id_to_last_child)
    let mut stack: Vec<(usize, usize, usize, usize, usize)> = Vec::new();

    for root in 0..n {
        if dfs_num[root] != usize::MAX {
            continue;
        }
        dfs_num[root] = time;
        low[root] = time;
        time += 1;
        stack.push((
            root,
            sym.offsets[root],
            NO_PARENT_EDGE,
            no_child,
            NO_PARENT_EDGE,
        ));

        while let Some(frame) = stack.last_mut() {
            if frame.3 != no_child {
                let u = frame.0;
                let c = frame.3;
                let tree_eid = frame.4;
                let lc = low[c];
                if lc < low[u] {
                    low[u] = lc;
                }
                if lc >= dfs_num[u] {
                    let mut verts: Vec<usize> = Vec::new();
                    while let Some(eid) = edge_stack.pop() {
                        let (a, b) = endpoints[eid];
                        verts.push(a);
                        verts.push(b);
                        if eid == tree_eid {
                            break;
                        }
                    }
                    verts.sort_unstable();
                    verts.dedup();
                    components.push(verts);
                }
                frame.3 = no_child;
                frame.4 = NO_PARENT_EDGE;
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
                // Already visited. Push only true back edges (the version where
                // the *current* endpoint is deeper). This dedups the two
                // half-edges in the symmetric view.
                if dfs_num[v] < dfs_num[u] {
                    edge_stack.push(eid);
                    let dv = dfs_num[v];
                    if dv < low[u] {
                        low[u] = dv;
                    }
                }
            } else {
                // Tree edge.
                dfs_num[v] = time;
                low[v] = time;
                time += 1;
                edge_stack.push(eid);
                frame.3 = v;
                frame.4 = eid;
                stack.push((v, sym.offsets[v], eid, no_child, NO_PARENT_EDGE));
            }
        }
    }

    Ok(components)
}
