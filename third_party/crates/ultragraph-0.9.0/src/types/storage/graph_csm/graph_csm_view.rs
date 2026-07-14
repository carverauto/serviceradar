/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CsmGraph, GraphView};

// A constant defined for the adaptive `contains_edge` algorithm.
const BINARY_SEARCH_THRESHOLD: usize = 64;

impl<N, W> GraphView<N, W> for CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Checks if the graph is in a frozen, high-performance state.
    /// For `CsmGraph`, this is always true by definition.
    fn is_frozen(&self) -> bool {
        true
    }

    fn is_empty(&self) -> bool {
        self.nodes.is_empty() && self.root_index.is_none()
    }

    /// Checks if a node exists at the given index.
    /// In a frozen `CsmGraph`, the node list is compact, so a simple bounds check is sufficient.
    fn contains_node(&self, index: usize) -> bool {
        index < self.nodes.len()
    }

    /// Retrieves a reference to the payload of a node at the given index.
    /// This uses the built-in `Vec::get` for safe, O(1) access.
    fn get_node(&self, index: usize) -> Option<&N> {
        self.nodes.get(index)
    }

    /// Returns the total number of nodes in the graph.
    fn number_nodes(&self) -> usize {
        self.nodes.len()
    }

    /// Checks if a directed edge exists from node `a` to node `b`.
    /// This uses the high-performance adaptive strategy defined in the SRS.
    fn contains_edge(&self, a: usize, b: usize) -> bool {
        // Ensure the source node exists before trying to access its edges.
        if a >= self.number_nodes() {
            return false;
        }

        // Get the slice of neighbors for node `a`. This is an O(1) operation.
        let start = self.forward_edges.offsets[a];
        let end = self.forward_edges.offsets[a + 1];

        // The slice is now taken from the dedicated `targets` vector. This is more
        // cache-efficient if the algorithm doesn't need the weights.
        let targets_slice = &self.forward_edges.targets[start..end];

        // Choose the best algorithm based on the number of neighbors.
        if targets_slice.len() < BINARY_SEARCH_THRESHOLD {
            // For small lists, a linear scan over a simple `Vec<usize>` is extremely fast.
            targets_slice.contains(&b)
        } else {
            // For larger lists, binary search is asymptotically faster.
            // This relies on the slice being pre-sorted by target index during `.freeze()`.
            targets_slice.binary_search(&b).is_ok()
        }
    }

    /// Returns the total number of edges in the graph.
    /// This is an O(1) operation, as it's just the length of the targets vector.
    fn number_edges(&self) -> usize {
        // The number of edges is the length of the flat targets vector.
        self.forward_edges.targets.len()
    }

    fn get_all_nodes(&self) -> Vec<&N> {
        self.nodes.iter().collect()
    }

    /// Retrieves a list of all outgoing edges from a given source node.
    /// Returns `None` if the source node does not exist.
    /// The returned vector contains tuples of `(target_node_index, edge_weight_reference)`.
    fn get_edges(&self, source: usize) -> Option<Vec<(usize, &W)>> {
        if !self.contains_node(source) {
            return None;
        }

        let start = self.forward_edges.offsets[source];
        let end = self.forward_edges.offsets[source + 1];

        // Get parallel slices for the targets and weights.
        let targets_slice = &self.forward_edges.targets[start..end];
        let weights_slice = &self.forward_edges.weights[start..end];

        // Use `zip` to combine the parallel slices back into tuples for the user.
        Some(
            targets_slice
                .iter()
                .zip(weights_slice.iter())
                .map(|(&target, weight)| (target, weight))
                .collect(),
        )
    }

    fn get_last_index(&self) -> Option<usize> {
        self.nodes.len().checked_sub(1)
    }

    /// Checks if a root node has been designated for this graph.
    fn contains_root_node(&self) -> bool {
        self.root_index.is_some()
    }

    /// Retrieves a reference to the payload of the designated root node, if one exists.
    fn get_root_node(&self) -> Option<&N> {
        // `and_then` provides a clean, functional way to chain Option lookups.
        self.root_index.and_then(|index| self.get_node(index))
    }

    /// Retrieves the index of the designated root node, if one exists.
    /// This is an O(1) operation.
    fn get_root_index(&self) -> Option<usize> {
        self.root_index
    }
}
