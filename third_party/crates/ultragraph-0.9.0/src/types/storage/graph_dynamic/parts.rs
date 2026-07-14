/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::DynamicGraph;
use crate::types::storage::graph_dynamic::DynamicGraphParts;

impl<N, W> DynamicGraph<N, W> {
    /// Creates a `DynamicGraph` directly from its constituent parts.
    ///
    /// This is the most performant way to construct a graph from an existing, validated
    /// dataset, as it bypasses the per-call overhead of methods like `add_edge`.
    ///
    /// # Preconditions
    /// The caller is responsible for ensuring the integrity of the data. Specifically:
    /// - The length of the `edges` vector must be exactly equal to the length of the `nodes` vector.
    /// - Every `usize` target index within the `edges` lists must be a valid index into the `nodes` vector
    ///   (i.e., less than `nodes.len()`).
    ///
    /// # Panics
    /// This method will panic in debug builds if `nodes.len() != edges.len()`. It may
    /// cause out-of-bounds panics later if the edge index precondition is violated by the caller.
    ///
    /// # Examples
    /// ```rust
    /// use ultragraph::{DynamicGraph, GraphView};
    ///
    /// // Node payloads: Node 1 is "tombstoned" (removed).
    /// let nodes = vec![Some("A"), None, Some("C")];
    ///
    /// // Adjacency lists:
    /// // Node 0 ("A") -> Node 2 ("C") with weight 10.
    /// // Node 1 (None) has no edges.
    /// // Node 2 ("C") -> Node 0 ("A") with weight 5.
    /// let edges = vec![
    ///     vec![(2, 10)],
    ///     vec![],
    ///     vec![(0, 5)],
    /// ];
    ///
    /// // The root node is at index 0.
    /// let root_index = Some(0);
    ///
    /// let parts = (nodes, edges, root_index);
    ///
    /// let graph = DynamicGraph::from_parts(parts);
    ///
    /// assert_eq!(graph.number_nodes(), 2); // Only counts non-tombstoned nodes.
    /// assert_eq!(graph.number_edges(), 2);
    /// assert!(graph.contains_edge(0, 2));
    /// ```
    ///
    pub fn from_parts(parts: DynamicGraphParts<N, W>) -> Self {
        let (nodes, edges, root_index) = parts;

        // A non-negotiable sanity check. This prevents gross structural mismatches.
        assert_eq!(
            nodes.len(),
            edges.len(),
            "The number of node payloads must equal the number of adjacency lists."
        );

        Self {
            nodes,
            edges,
            root_index,
            // When building from parts, we assume the user has already handled capacity.
            num_edges_per_node: None,
        }
    }

    /// Consumes the graph and returns its raw component parts.
    ///
    /// This method deconstructs the graph into a tuple containing its internal node
    /// vector, adjacency list, and root index. This is an O(1) operation as it
    /// simply moves ownership of the internal data.
    ///
    /// It is the inverse of `from_parts`, making it useful for serialization or for
    /// moving the graph's data to another system.
    ///
    /// # Returns
    ///
    /// A tuple `(nodes, edges, root_index)` wrapped in the `DynamicGraphParts` type alias.
    /// - `nodes`: A `Vec<Option<N>>` of node payloads.
    /// - `edges`: A `Vec<Vec<(usize, W)>>` representing the adjacency list.
    /// - `root_index`: An `Option<usize>` for the root node.
    ///
    pub fn to_parts(self) -> DynamicGraphParts<N, W> {
        (self.nodes, self.edges, self.root_index)
    }
}
