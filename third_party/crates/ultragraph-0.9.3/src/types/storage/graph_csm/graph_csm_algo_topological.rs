/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CsmGraph, GraphError, GraphView, TopologicalGraphAlgorithms};
use std::collections::VecDeque;
use std::slice;

/// Private enum representing the state of a node during a DFS traversal.
/// It is not part of the public API.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum NodeState {
    /// The node has not yet been visited.
    Unvisited,
    /// The node is currently in the recursion stack (being visited).
    VisitingInProgress,
    /// The node and all its descendants have been fully visited and are known to be cycle-free.
    Visited,
}

impl<N, W> TopologicalGraphAlgorithms<N, W> for CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Finds a cycle in the graph using an iterative Depth-First Search (DFS).
    ///
    /// This method traverses the graph to detect a back edge, which indicates a cycle.
    /// The iterative approach using an explicit stack makes it robust against stack
    /// overflows, even for very deep or large graphs. The search is comprehensive and
    /// will find a cycle in any of the graph's disconnected components if one exists.
    ///
    /// # Returns
    ///
    /// - `Some(Vec<usize>)`: If a cycle is found, this returns a vector of node indices
    ///   that form the cycle. The path explicitly starts and ends with the same node
    ///   to represent the closed loop (e.g., `[1, 2, 0, 1]`). For a self-loop on
    ///   node `n`, it returns `vec![n, n]`.
    /// - `None`: If the graph is a Directed Acyclic Graph (DAG) and contains no cycles.
    ///
    /// # Complexity
    ///
    /// - **Time Complexity:** O(V + E), where V is the number of nodes and E is the
    ///   number of edges, as each node and edge is visited exactly once.
    /// - **Space Complexity:** O(V) for storing node states, predecessors, and the DFS stack.
    ///
    fn find_cycle(&self) -> Result<Option<Vec<usize>>, GraphError> {
        let num_nodes = self.number_nodes();
        if num_nodes == 0 {
            return Ok(None);
        }

        let mut states = vec![NodeState::Unvisited; num_nodes];
        let mut predecessors = vec![None; num_nodes];

        for i in 0..num_nodes {
            if states[i] == NodeState::Unvisited {
                // We use the concrete `slice::Iter` type to avoid Box and dynamic dispatch.
                let mut stack: Vec<(usize, slice::Iter<'_, usize>)> = Vec::new();

                // By accessing the internal fields directly, we bypass the opaque `impl Trait`
                // returned by the `outbound_edges` trait method.
                let start = self.forward_edges.offsets[i];
                let end = self.forward_edges.offsets[i + 1];
                let neighbors = self.forward_edges.targets[start..end].iter();

                states[i] = NodeState::VisitingInProgress;
                stack.push((i, neighbors));

                while let Some((u_ref, neighbors)) = stack.last_mut() {
                    let u = *u_ref;

                    if let Some(&v) = neighbors.next() {
                        if states[v] == NodeState::VisitingInProgress {
                            // --- Cycle Found: Reconstruct the Path ---
                            let mut path = vec![u];
                            let mut current = u;

                            while let Some(predecessor) = predecessors[current] {
                                path.push(predecessor);
                                if predecessor == v {
                                    break;
                                }
                                current = predecessor;
                            }
                            path.reverse();
                            path.push(v); // Make the cycle explicit: [v, ..., u, v]
                            return Ok(Some(path));
                        }

                        if states[v] == NodeState::Unvisited {
                            predecessors[v] = Some(u);
                            states[v] = NodeState::VisitingInProgress;

                            let v_start = self.forward_edges.offsets[v];
                            let v_end = self.forward_edges.offsets[v + 1];
                            let v_neighbors = self.forward_edges.targets[v_start..v_end].iter();
                            stack.push((v, v_neighbors));
                        }
                    } else {
                        // If the neighbor iterator is exhausted, we are done with this node.
                        states[u] = NodeState::Visited;
                        stack.pop();
                    }
                }
            }
        }

        Ok(None) // No cycles found after checking all nodes.
    }

    /// Checks if the graph contains any directed cycles.
    ///
    /// This implementation leverages the iterative `topological_sort` method,
    /// making it a highly robust way to detect cycles in graphs of any size
    /// without risking a stack overflow.
    fn has_cycle(&self) -> Result<bool, GraphError> {
        match self.topological_sort() {
            Ok(Some(_)) => Ok(false),
            Ok(None) => Ok(true),
            Err(e) => Err(e),
        }
    }

    /// Computes a topological sort of the graph using the iterative Kahn's algorithm.
    ///
    /// This method is robust against stack overflows, making it suitable for graphs
    /// of any size. It works by repeatedly finding nodes with no incoming edges.
    ///
    /// # Returns
    /// - `Some(Vec<usize>)` if the graph is a Directed Acyclic Graph (DAG). The
    ///   vector contains the nodes in a valid topological order.
    /// - `None` if the graph contains a cycle, as a topological sort is not possible.
    fn topological_sort(&self) -> Result<Option<Vec<usize>>, GraphError> {
        let num_nodes = self.number_nodes();
        if num_nodes == 0 {
            // An empty graph is trivially sorted.
            return Ok(Some(Vec::new()));
        }

        // 1. Compute in-degrees for all nodes.
        let mut in_degrees = vec![0; num_nodes];
        for i in 0..num_nodes {
            //  Access CSR arrays directly for max performance.
            let start = self.forward_edges.offsets[i];
            let end = self.forward_edges.offsets[i + 1];
            for &neighbor in &self.forward_edges.targets[start..end] {
                in_degrees[neighbor] += 1;
            }
        }

        // 2. Initialize a queue with all nodes that have an in-degree of 0.
        let mut queue: VecDeque<usize> = (0..num_nodes).filter(|&i| in_degrees[i] == 0).collect();

        // 3. Process the queue.
        let mut sorted_list = Vec::with_capacity(num_nodes);
        while let Some(u) = queue.pop_front() {
            sorted_list.push(u);

            // For each neighbor of the dequeued node, decrement its in-degree.
            //  Access CSR arrays directly.
            let start = self.forward_edges.offsets[u];
            let end = self.forward_edges.offsets[u + 1];
            for &v in &self.forward_edges.targets[start..end] {
                in_degrees[v] -= 1;
                if in_degrees[v] == 0 {
                    queue.push_back(v);
                }
            }
        }

        // 4. Validate the result.
        if sorted_list.len() == num_nodes {
            Ok(Some(sorted_list))
        } else {
            Ok(None) // Cycle detected
        }
    }
}
