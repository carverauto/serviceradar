/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CsmGraph, GraphError, GraphView, PathfindingGraphAlgorithms};
use std::cmp::Reverse;
use std::collections::{BinaryHeap, VecDeque};

impl<N, W> PathfindingGraphAlgorithms<N, W> for CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Checks if a path exists from a start to a stop index.
    fn is_reachable(&self, start_index: usize, stop_index: usize) -> Result<bool, GraphError> {
        match self.shortest_path_len(start_index, stop_index) {
            Ok(Some(_)) => Ok(true),
            Ok(None) => Ok(false),
            Err(e) => Err(e),
        }
    }

    /// Returns the length of the shortest path (in number of nodes) from a start to a stop index.
    fn shortest_path_len(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Option<usize>, GraphError> {
        if !self.contains_node(start_index) || !self.contains_node(stop_index) {
            return Ok(None);
        }
        if start_index == stop_index {
            return Ok(Some(1));
        }

        let mut queue = VecDeque::new();
        let mut visited = vec![false; self.number_nodes()];

        queue.push_back((start_index, 1)); // (node, path_length)
        visited[start_index] = true;

        while let Some((current_node, current_len)) = queue.pop_front() {
            //  Access CSR arrays directly.
            let start = self.forward_edges.offsets[current_node];
            let end = self.forward_edges.offsets[current_node + 1];
            for &neighbor in &self.forward_edges.targets[start..end] {
                if neighbor == stop_index {
                    return Ok(Some(current_len + 1));
                }
                if !visited[neighbor] {
                    visited[neighbor] = true;
                    queue.push_back((neighbor, current_len + 1));
                }
            }
        }
        Ok(None)
    }

    /// Finds the complete shortest path from a start to a stop index.
    fn shortest_path(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Option<Vec<usize>>, GraphError> {
        if !self.contains_node(start_index) || !self.contains_node(stop_index) {
            return Ok(None);
        }
        if start_index == stop_index {
            return Ok(Some(vec![start_index]));
        }

        let mut queue = VecDeque::new();
        let mut predecessors = vec![None; self.number_nodes()];
        let mut visited = vec![false; self.number_nodes()];

        queue.push_back(start_index);
        visited[start_index] = true;

        let mut found = false;
        'bfs_loop: while let Some(current_node) = queue.pop_front() {
            //  Access CSR arrays directly.
            let start = self.forward_edges.offsets[current_node];
            let end = self.forward_edges.offsets[current_node + 1];
            for &neighbor in &self.forward_edges.targets[start..end] {
                if !visited[neighbor] {
                    visited[neighbor] = true;
                    predecessors[neighbor] = Some(current_node);
                    queue.push_back(neighbor);

                    if neighbor == stop_index {
                        found = true;
                        break 'bfs_loop;
                    }
                }
            }
        }

        if !found {
            return Ok(None);
        }

        // Reconstruct path by walking backwards from the stop index.
        let mut path = Vec::new();
        let mut current = Some(stop_index);
        while let Some(curr_index) = current {
            path.push(curr_index);
            current = predecessors[curr_index];
        }
        path.reverse();
        Ok(Some(path))
    }

    fn shortest_weighted_path(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Option<(Vec<usize>, W)>, GraphError>
    where
        W: Copy + Ord + Default + std::ops::Add<Output = W>,
    {
        if !self.contains_node(start_index) || !self.contains_node(stop_index) {
            return Ok(None);
        }

        if start_index == stop_index {
            return Ok(Some((vec![start_index], W::default())));
        }

        let num_nodes = self.number_nodes();
        let mut distances: Vec<Option<W>> = vec![None; num_nodes];
        let mut predecessors: Vec<Option<usize>> = vec![None; num_nodes];
        let mut pq: BinaryHeap<(Reverse<W>, usize)> = BinaryHeap::new();

        distances[start_index] = Some(W::default());
        pq.push((Reverse(W::default()), start_index));

        while let Some((Reverse(dist), u)) = pq.pop() {
            if u == stop_index {
                let mut path = Vec::new();
                let mut current = Some(stop_index);
                while let Some(node) = current {
                    path.push(node);
                    if node == start_index {
                        break;
                    }
                    current = predecessors[node];
                }
                path.reverse();

                return Ok(Some((path, dist)));
            }

            if let Some(known_dist) = distances[u]
                && dist > known_dist
            {
                continue;
            }

            let start_offset = self.forward_edges.offsets[u];
            let end_offset = self.forward_edges.offsets[u + 1];

            for i in start_offset..end_offset {
                let v = self.forward_edges.targets[i];
                let weight = self.forward_edges.weights[i];
                let new_dist = dist + weight;

                if distances[v].is_none() || new_dist < distances[v].unwrap() {
                    distances[v] = Some(new_dist);
                    predecessors[v] = Some(u);
                    pq.push((Reverse(new_dist), v));
                }
            }
        }

        Ok(None)
    }
}
