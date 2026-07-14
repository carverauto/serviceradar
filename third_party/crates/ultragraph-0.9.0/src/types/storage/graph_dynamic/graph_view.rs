/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{DynamicGraph, GraphView};

impl<N, W> GraphView<N, W> for DynamicGraph<N, W> {
    /// Checks if the graph is in a frozen, high-performance state.
    /// For `DynamicGraph`, this is by definition always false.
    fn is_frozen(&self) -> bool {
        false
    }

    fn is_empty(&self) -> bool {
        self.nodes.iter().all(Option::is_none) && self.root_index.is_none()
    }

    /// Checks if a valid, non-tombstoned node exists at the given index.
    fn contains_node(&self, index: usize) -> bool {
        // `is_some_and` first checks if the index is in bounds (`get` returns `Some`),
        // and then checks if the inner Option is also `Some`.
        self.nodes
            .get(index)
            .is_some_and(|node_opt| node_opt.is_some())
    }

    /// Retrieves a reference to the payload of a node, if it exists and has not been removed.
    fn get_node(&self, index: usize) -> Option<&N> {
        // We first get the `Option<&Option<N>>` which handles the bounds check.
        // Then, `and_then` unwraps the outer Option and `as_ref` converts `&Option<N>` to `Option<&N>`.
        self.nodes.get(index).and_then(|node_opt| node_opt.as_ref())
    }

    /// Returns the total number of valid, non-tombstoned nodes in the graph.
    ///
    /// Note: This is an O(V) operation for `DynamicGraph` as it must iterate
    /// to ignore any removed ("tombstoned") nodes.
    fn number_nodes(&self) -> usize {
        self.nodes.iter().filter(|n| n.is_some()).count()
    }

    /// Checks if a directed edge exists from node `a` to node `b`.
    fn contains_edge(&self, a: usize, b: usize) -> bool {
        // We get the edge list for node `a`. If `a` is out of bounds or has been removed,
        // `get` will return `None`, and the `map_or` will correctly return `false`.
        self.edges.get(a).is_some_and(|edge_list| {
            // Then we simply check if any edge in that list points to `b`
            // and that the target node is not tombstoned.
            edge_list
                .iter()
                .any(|(target, _)| *target == b && self.contains_node(*target))
        })
    }

    /// Returns the total number of edges in the graph.
    ///
    /// Note: This is an O(V) operation for `DynamicGraph` as it must iterate
    /// through the outer vector to sum the lengths of the inner edge lists.
    fn number_edges(&self) -> usize {
        self.edges.iter().map(|edge_list| edge_list.len()).sum()
    }

    fn get_all_nodes(&self) -> Vec<&N> {
        self.nodes.iter().filter_map(Option::as_ref).collect()
    }

    /// Retrieves a list of all outgoing edges from a given source node.
    /// Returns `None` if the source node does not exist.
    /// The returned vector contains tuples of `(target_node_index, edge_weight_reference)`.
    fn get_edges(&self, source: usize) -> Option<Vec<(usize, &W)>> {
        if !self.contains_node(source) {
            return None;
        }
        // Filter out edges to tombstoned nodes during iteration
        let edges: Vec<(usize, &W)> = self
            .edges
            .get(source)?
            .iter()
            .filter_map(|(target, weight)| {
                if self.contains_node(*target) {
                    Some((*target, weight))
                } else {
                    None
                }
            })
            .collect();
        Some(edges)
    }

    fn get_last_index(&self) -> Option<usize> {
        self.nodes.iter().rposition(|node| node.is_some())
    }

    /// Checks if a valid, non-tombstoned root node has been designated.
    fn contains_root_node(&self) -> bool {
        // Use `is_some_and` to check both that a root_index exists AND
        // that the node at that index is still valid.
        self.root_index
            .is_some_and(|index| self.contains_node(index))
    }

    /// Retrieves a reference to the payload of the designated root node, if it exists and is valid.
    fn get_root_node(&self) -> Option<&N> {
        // We chain options: get the root index, then use that to get the node data.
        self.root_index.and_then(|index| self.get_node(index))
    }

    /// Retrieves the index of the designated root node, if one exists and is valid.
    fn get_root_index(&self) -> Option<usize> {
        // We use `filter` to return the index only if the node at that index is still valid.
        self.root_index.filter(|&index| self.contains_node(index))
    }
}
