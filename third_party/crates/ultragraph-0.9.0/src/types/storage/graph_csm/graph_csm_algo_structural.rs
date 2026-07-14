/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CsmGraph, GraphError, GraphView, StructuralGraphAlgorithms};
use std::slice;

impl<N, W> StructuralGraphAlgorithms<N, W> for CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Finds all Strongly Connected Components in the graph using Tarjan's algorithm.
    ///
    /// # Returns
    /// A vector of vectors, where each inner vector is a list of node indices
    /// belonging to a single SCC.
    fn strongly_connected_components(&self) -> Result<Vec<Vec<usize>>, GraphError> {
        let num_nodes = self.number_nodes();
        if num_nodes == 0 {
            return Ok(Vec::new());
        }

        let mut dfs_num: Vec<Option<usize>> = vec![None; num_nodes];
        let mut low_link: Vec<Option<usize>> = vec![None; num_nodes];
        let mut on_stack: Vec<bool> = vec![false; num_nodes];
        let mut tarjan_stack: Vec<usize> = Vec::new();
        let mut time: usize = 0;
        let mut sccs: Vec<Vec<usize>> = Vec::new();

        // Stack for iterative DFS. Stores (node_index, iterator_over_neighbors)
        // The iterator is used to keep track of which neighbor to visit next.
        let mut dfs_stack: Vec<(usize, slice::Iter<'_, usize>)> = Vec::new();

        for i in 0..num_nodes {
            if dfs_num[i].is_none() {
                // Start DFS from node i
                let start_offset = self.forward_edges.offsets[i];
                let end_offset = self.forward_edges.offsets[i + 1];
                let neighbors_iter = self.forward_edges.targets[start_offset..end_offset].iter();
                dfs_stack.push((i, neighbors_iter));

                // Simulate recursion
                while let Some((u, neighbors)) = dfs_stack.last_mut() {
                    // On first visit to u (pre-order traversal)
                    if dfs_num[*u].is_none() {
                        dfs_num[*u] = Some(time);
                        low_link[*u] = Some(time);
                        time += 1;
                        tarjan_stack.push(*u);
                        on_stack[*u] = true;
                    }

                    // Process neighbors
                    if let Some(&v) = neighbors.next() {
                        if dfs_num[v].is_none() {
                            // Neighbor v not visited, "recurse"
                            let v_start_offset = self.forward_edges.offsets[v];
                            let v_end_offset = self.forward_edges.offsets[v + 1];
                            let v_neighbors_iter =
                                self.forward_edges.targets[v_start_offset..v_end_offset].iter();
                            dfs_stack.push((v, v_neighbors_iter));
                        } else if on_stack[v] {
                            // Neighbor v is on stack, back-edge
                            low_link[*u] = Some(
                                low_link[*u]
                                    .ok_or(GraphError::AlgorithmError("low_link for u not set"))?
                                    .min(dfs_num[v].ok_or(GraphError::AlgorithmError(
                                        "dfs_num for v not set",
                                    ))?),
                            );
                        }
                    } else {
                        // All neighbors processed, "return" from u (post-order traversal)

                        // If u is the root of an SCC
                        if dfs_num[*u] == low_link[*u] {
                            let mut current_scc = Vec::new();
                            loop {
                                let node = tarjan_stack
                                    .pop()
                                    .ok_or(GraphError::AlgorithmError("tarjan_stack is empty"))?;
                                on_stack[node] = false;
                                current_scc.push(node);
                                if node == *u {
                                    break;
                                }
                            }
                            current_scc.reverse(); // SCC nodes are popped in reverse order
                            sccs.push(current_scc);
                        }

                        // Update parent's low_link if u is not the root of an SCC
                        // This must happen AFTER processing the current node's SCC, but BEFORE popping u from dfs_stack
                        let popped_u = dfs_stack
                            .pop()
                            .ok_or(GraphError::AlgorithmError("DFS stack was empty in a post-order step, which should be impossible"))?
                            .0;

                        if let Some((parent_node, _)) = dfs_stack.last() {
                            low_link[*parent_node] = Some(
                                low_link[*parent_node]
                                    .ok_or(GraphError::AlgorithmError(
                                        "low_link for parent_node not set",
                                    ))?
                                    .min(low_link[popped_u].ok_or(GraphError::AlgorithmError(
                                        "low_link for popped_u not set",
                                    ))?),
                            );
                        }
                    }
                }
            }
        }

        Ok(sccs)
    }

    fn articulation_points(&self) -> Result<Vec<usize>, GraphError> {
        super::graph_csm_algo_articulation_points::articulation_points_impl(self)
    }

    fn bridges(&self) -> Result<Vec<(usize, usize)>, GraphError> {
        super::graph_csm_algo_bridges::bridges_impl(self)
    }

    fn biconnected_components(&self) -> Result<Vec<Vec<usize>>, GraphError> {
        super::graph_csm_algo_biconnected_components::biconnected_components_impl(self)
    }
}
