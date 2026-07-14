/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CentralityGraphAlgorithms, CsmGraph, GraphError, GraphView};
use std::collections::HashSet;
use std::collections::VecDeque;

impl<N, W> CentralityGraphAlgorithms<N, W> for CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Calculates the betweenness centrality of each node in the graph.
    fn betweenness_centrality(
        &self,
        directed: bool,
        normalized: bool,
    ) -> Result<Vec<(usize, f64)>, GraphError> {
        let num_nodes = self.number_nodes();
        if num_nodes == 0 {
            return Ok(Vec::new());
        }

        let mut centrality = vec![0.0; num_nodes];

        // Betweenness centrality is 0 for graphs with less than 3 nodes.
        if num_nodes < 3 {
            return Ok(centrality.into_iter().enumerate().collect());
        }

        for s in 0..num_nodes {
            let (_, sigma, pred, mut stack) = self._brandes_bfs_and_path_counting(s, directed)?;

            // Accumulation
            let mut delta = vec![0.0; num_nodes];
            while let Some(w) = stack.pop() {
                for &v in &pred[w] {
                    let sigma_v = sigma[v];
                    let sigma_w = sigma[w];
                    delta[v] += (sigma_v / sigma_w) * (1.0 + delta[w]);
                }
                if w != s {
                    centrality[w] += delta[w];
                }
            }
        }

        // It aligns the code with the standard formal definition.
        if !directed {
            for score in centrality.iter_mut() {
                *score /= 2.0;
            }
        }

        // Normalization
        if normalized {
            let scale = if directed {
                ((num_nodes - 1) * (num_nodes - 2)) as f64
            } else {
                ((num_nodes - 1) * (num_nodes - 2)) as f64 / 2.0
            };

            if scale > 0.0 {
                for score in centrality.iter_mut() {
                    *score /= scale;
                }
            }
        }

        Ok(centrality.into_iter().enumerate().collect())
    }

    /// Calculates betweenness centrality across a specific set of critical pathways.
    fn pathway_betweenness_centrality(
        &self,
        pathways: &[(usize, usize)],
        directed: bool,
        normalized: bool,
    ) -> Result<Vec<(usize, f64)>, GraphError> {
        let num_nodes = self.number_nodes();
        if num_nodes == 0 {
            return Ok(vec![]);
        }

        let mut centrality = vec![0.0; num_nodes];
        let mut valid_pathways = 0;

        // Unlike the global version, we cannot easily group by source,
        // as the dependency calculation is specific to each target `t`.
        for &(s, t) in pathways {
            if !self.contains_node(s) || !self.contains_node(t) {
                continue;
            }

            if s == t {
                valid_pathways += 1;
                continue;
            }

            // We need a fresh BFS for each s->t pair to get the correct stack order
            let (dist, sigma, pred, mut stack) =
                self._brandes_bfs_and_path_counting(s, directed)?;

            // If t is not reachable from s, this pathway contributes nothing.
            if dist[t].is_none() {
                continue;
            }
            valid_pathways += 1;

            let mut delta = vec![0.0; num_nodes];

            // Process nodes in reverse order from the stack
            while let Some(w) = stack.pop() {
                // The contribution to dependency is only propagated from nodes on a shortest path to t.
                // This can be simplified: if a node `w` is part of an s-t path, its `delta` will be non-zero
                // if one of its successors on the shortest path has non-zero delta. We start this at `t`.
                if w == t {
                    // This is the starting point of our back-propagation for this s-t path
                    delta[w] = 1.0;
                }

                for &v in &pred[w] {
                    // The dependency of v is its share of the dependency of w.
                    if sigma[w] > 0.0 {
                        delta[v] += (sigma[v] / sigma[w]) * delta[w];
                    }
                }
            }

            // Add the accumulated dependencies to the final centrality scores
            // The endpoints s and t themselves do not get centrality credit from this path.
            for i in 0..num_nodes {
                if i != s && i != t {
                    centrality[i] += delta[i];
                }
            }
        }

        if normalized && valid_pathways > 0 {
            let scale = valid_pathways as f64;
            for score in &mut centrality {
                *score /= scale;
            }
        }

        Ok(centrality.into_iter().enumerate().collect())
    }
}

impl<N, W> CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Private helper for Brandes' algorithm: BFS and path counting phase.
    /// Returns (dist, sigma, pred, stack)
    #[allow(clippy::type_complexity)]
    #[inline]
    fn _brandes_bfs_and_path_counting(
        &self,
        s: usize,
        directed: bool,
    ) -> Result<(Vec<Option<usize>>, Vec<f64>, Vec<Vec<usize>>, Vec<usize>), GraphError> {
        let num_nodes = self.number_nodes();
        let mut stack = Vec::new(); // S in Brandes' algorithm
        let mut queue = VecDeque::new();
        let mut dist = vec![None; num_nodes];
        let mut sigma = vec![0.0; num_nodes]; // Number of shortest paths
        let mut pred: Vec<Vec<usize>> = vec![Vec::new(); num_nodes]; // Predecessors on shortest paths
        let mut neighbors_to_process = Vec::new(); // Reused to avoid reallocations

        dist[s] = Some(0);
        sigma[s] = 1.0;
        queue.push_back(s);

        while let Some(v) = queue.pop_front() {
            stack.push(v);
            neighbors_to_process.clear(); // Clear for current node
            if directed {
                let start = self.forward_edges.offsets[v];
                let end = self.forward_edges.offsets[v + 1];
                for &neighbor in &self.forward_edges.targets[start..end] {
                    neighbors_to_process.push(neighbor);
                }
            // For undirected, consider both forward and backward neighbors
            } else {
                let start_fwd = self.forward_edges.offsets[v];
                let end_fwd = self.forward_edges.offsets[v + 1];
                for &neighbor in &self.forward_edges.targets[start_fwd..end_fwd] {
                    neighbors_to_process.push(neighbor);
                }
                let start_bwd = self.backward_edges.offsets[v];
                let end_bwd = self.backward_edges.offsets[v + 1];
                for &neighbor in &self.backward_edges.targets[start_bwd..end_bwd] {
                    neighbors_to_process.push(neighbor);
                }
                // Use HashSet for efficient deduplication
                let unique_neighbors: HashSet<usize> = neighbors_to_process.drain(..).collect();
                neighbors_to_process.extend(unique_neighbors);
            }

            for &w in &neighbors_to_process {
                let v_dist = dist[v].ok_or(GraphError::AlgorithmError("Distance for v not set"))?;
                // Path discovery
                if dist[w].is_none() {
                    dist[w] = Some(v_dist + 1);
                    queue.push_back(w);
                }
                // Path counting
                if dist[w].ok_or(GraphError::AlgorithmError("Distance for w not set"))?
                    == v_dist + 1
                {
                    sigma[w] += sigma[v];
                    pred[w].push(v);
                }
            }
        }
        Ok((dist, sigma, pred, stack))
    }
}
