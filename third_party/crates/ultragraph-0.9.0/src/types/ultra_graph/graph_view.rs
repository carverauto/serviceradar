/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GraphState, GraphView, UltraGraphContainer};

impl<N, W> GraphView<N, W> for UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Returns `true` if the graph is in the immutable, performance-optimized `Static` state.
    /// A static graph cannot be frozen only once. If you want to modify a static graph i.e. adding
    /// new nodes or edges you have to unfreeze it first using the unfreeze method.
    ///
    /// Returns `false` if the graph is in the dynamic mutable-optimized `Dynamic` state.
    /// A dynamic graph must be frozen before analytics algorithms become available. You have to
    /// call freeze to do so.
    fn is_frozen(&self) -> bool {
        matches!(self.state, GraphState::Static(_))
    }

    fn is_empty(&self) -> bool {
        match &self.state {
            GraphState::Dynamic(g) => g.is_empty(),
            GraphState::Static(g) => g.is_empty(),
        }
    }

    /// Checks if a node exists at the given index.
    fn contains_node(&self, index: usize) -> bool {
        match &self.state {
            GraphState::Dynamic(g) => g.contains_node(index),
            GraphState::Static(g) => g.contains_node(index),
        }
    }

    /// Retrieves a reference to the payload of a node at the given index.
    fn get_node(&self, index: usize) -> Option<&N> {
        match &self.state {
            GraphState::Dynamic(g) => g.get_node(index),
            GraphState::Static(g) => g.get_node(index),
        }
    }

    /// Returns the number of nodes in the graph.
    fn number_nodes(&self) -> usize {
        match &self.state {
            GraphState::Dynamic(g) => g.number_nodes(),
            GraphState::Static(g) => g.number_nodes(),
        }
    }

    /// Checks if an edge exists between two nodes.
    fn contains_edge(&self, a: usize, b: usize) -> bool {
        match &self.state {
            GraphState::Dynamic(g) => g.contains_edge(a, b),
            GraphState::Static(g) => g.contains_edge(a, b),
        }
    }

    /// Returns the number of edges in the graph.
    fn number_edges(&self) -> usize {
        match &self.state {
            GraphState::Dynamic(g) => g.number_edges(),
            GraphState::Static(g) => g.number_edges(),
        }
    }

    /// The order of the nodes in the returned vector is not guaranteed.
    /// This operation is O(V) as it iterates through all possible node slots
    fn get_all_nodes(&self) -> Vec<&N> {
        match &self.state {
            GraphState::Dynamic(g) => g.get_all_nodes(),
            GraphState::Static(g) => g.get_all_nodes(),
        }
    }

    /// Returns a list of outgoing edges from a source node, including target index and weight.
    /// Returns `None` if the source node does not exist.
    /// The returned vector contains tuples of `(target_node_index, edge_weight_reference)`.
    fn get_edges(&self, source: usize) -> Option<Vec<(usize, &W)>> {
        match &self.state {
            GraphState::Dynamic(g) => g.get_edges(source),
            GraphState::Static(g) => g.get_edges(source),
        }
    }

    fn get_last_index(&self) -> Option<usize> {
        match &self.state {
            GraphState::Dynamic(g) => g.get_last_index(),
            GraphState::Static(g) => g.get_last_index(),
        }
    }

    /// Checks if a root node currently exists in the graph.
    fn contains_root_node(&self) -> bool {
        match &self.state {
            GraphState::Dynamic(g) => g.contains_root_node(),
            GraphState::Static(g) => g.contains_root_node(),
        }
    }

    /// Retrieves an immutable reference to the data stored in the root node.
    fn get_root_node(&self) -> Option<&N> {
        match &self.state {
            GraphState::Dynamic(g) => g.get_root_node(),
            GraphState::Static(g) => g.get_root_node(),
        }
    }

    /// Retrieves the index of the root node.
    fn get_root_index(&self) -> Option<usize> {
        match &self.state {
            GraphState::Dynamic(g) => g.get_root_index(),
            GraphState::Static(g) => g.get_root_index(),
        }
    }
}
