/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod default;
mod graph_freeze;
mod graph_mut;
mod graph_view;
mod parts;

/// A tuple representing the raw components of a `DynamicGraph`.
///
/// Consists of `(nodes, edges, root_index)`.
pub type DynamicGraphParts<N, W> = (Vec<Option<N>>, Vec<Vec<(usize, W)>>, Option<usize>);

#[derive(Clone, Debug)]
pub struct DynamicGraph<N, W> {
    // Optional pre-allocated capacity for each node's edge list.
    // This is a performance optimization set by `with_capacity`.
    // By default, no edge capacity is pre-allocated.
    num_edges_per_node: Option<usize>,
    // Node payloads, indexed directly by `usize`.
    // The use of `Option` allows for efficient O(1) node removal ("tombstoning")
    // without invalidating other node indices.
    nodes: Vec<Option<N>>,

    // Adjacency list: A vector where each index corresponds to a source node,
    // and the value is a list of its outgoing edges.
    edges: Vec<Vec<(usize, W)>>,

    // Index of the designated root node.
    root_index: Option<usize>,
}

impl<N, W> DynamicGraph<N, W> {
    pub fn root_index(&self) -> Option<usize> {
        self.root_index
    }
}

impl<N, W> DynamicGraph<N, W> {
    /// Creates a new, empty `DynamicGraph`.
    ///
    /// The graph is initialized with no nodes, no edges, and no capacity. This is
    /// ideal for building a graph when the final size is unknown.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use ultragraph::DynamicGraph; // Replace with your crate name
    ///
    /// let graph = DynamicGraph::<String, u32>::new();
    /// // assert_eq!(graph.number_nodes(), 0);
    /// ```
    pub fn new() -> Self {
        Self {
            num_edges_per_node: None,
            nodes: Vec::new(),
            edges: Vec::new(),
            root_index: None,
        }
    }

    /// Creates a new, empty `DynamicGraph` with pre-allocated capacity.
    ///
    /// This is the most efficient way to start building a large graph when the
    /// approximate final size is known, as it can reduce or eliminate costly
    /// memory reallocations during the `add_node` process.
    ///
    /// # Arguments
    /// * `num_nodes`: The number of nodes to pre-allocate space for.
    /// * `num_edges_per_node`: An optional hint for the average number of outgoing
    ///   edges per node. Providing this pre-allocates memory for edge lists,
    ///   making `add_edge` calls more performant and predictable by avoiding
    ///   reallocations. If `None`, no capacity is pre-allocated for edges.
    ///
    /// # Note on Capacity
    ///
    /// This method pre-allocates the main vector for nodes and the outer vector for
    /// the adjacency list. It does not pre-allocate the inner vectors for each
    /// node's specific edge list, as their individual sizes are not known upfront.
    pub fn with_capacity(num_nodes: usize, num_edges_per_node: Option<usize>) -> Self {
        Self {
            num_edges_per_node,
            nodes: Vec::with_capacity(num_nodes),
            edges: Vec::with_capacity(num_nodes),
            root_index: None,
        }
    }
}

impl<N, W> DynamicGraph<N, W> {
    // Internal helper for unfreeze
    pub(crate) fn construct(
        nodes: Vec<Option<N>>,
        edges: Vec<Vec<(usize, W)>>,
        root_index: Option<usize>,
    ) -> Self {
        Self {
            num_edges_per_node: None,
            nodes,
            edges,
            root_index,
        }
    }
}
