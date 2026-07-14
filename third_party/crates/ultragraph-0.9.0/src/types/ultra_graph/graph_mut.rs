/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{DynamicGraph, GraphError, GraphMut, GraphState, UltraGraphContainer};

impl<N, W> GraphMut<N, W> for UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Adds a new node with the given payload to the graph.
    ///
    /// # Errors
    ///
    /// Returns `GraphError::GraphIsFrozen` if the graph is in a `Static` (frozen) state.
    fn add_node(&mut self, node: N) -> Result<usize, GraphError> {
        match &mut self.state {
            // Corrected: Directly return the result from the inner call.
            GraphState::Dynamic(g) => g.add_node(node),
            GraphState::Static(_) => Err(GraphError::GraphIsFrozen),
        }
    }

    /// Updates the payload of an existing node at a given index.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphIsFrozen` if the graph is in a `Static` state.
    /// - Returns an error if the node at the given index does not exist.
    fn update_node(&mut self, index: usize, node: N) -> Result<(), GraphError> {
        match &mut self.state {
            GraphState::Dynamic(g) => g.update_node(index, node),
            GraphState::Static(_) => Err(GraphError::GraphIsFrozen),
        }
    }

    /// Removes a node at the given index, also removing all edges connected to it.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphIsFrozen` if the graph is in a `Static` state.
    /// - Returns an error if the node at the given index does not exist.
    fn remove_node(&mut self, index: usize) -> Result<(), GraphError> {
        match &mut self.state {
            GraphState::Dynamic(g) => g.remove_node(index),
            GraphState::Static(_) => Err(GraphError::GraphIsFrozen),
        }
    }

    /// Adds a weighted edge between two nodes.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphIsFrozen` if the graph is in a `Static` state.
    /// - Returns an error if either node index is invalid or the edge already exists.
    fn add_edge(&mut self, a: usize, b: usize, weight: W) -> Result<(), GraphError> {
        match &mut self.state {
            GraphState::Dynamic(g) => g.add_edge(a, b, weight),
            GraphState::Static(_) => Err(GraphError::GraphIsFrozen),
        }
    }

    /// Removes an edge between two nodes.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphIsFrozen` if the graph is in a `Static` state.
    /// - Returns an error if either node index is invalid or the edge does not exist.
    fn remove_edge(&mut self, a: usize, b: usize) -> Result<(), GraphError> {
        match &mut self.state {
            GraphState::Dynamic(g) => g.remove_edge(a, b),
            GraphState::Static(_) => Err(GraphError::GraphIsFrozen),
        }
    }

    /// Adds a new node and designates it as the root of the graph.
    ///
    /// # Errors
    ///
    /// Returns `GraphError::GraphIsFrozen` if the graph is in a `Static` (frozen) state.
    fn add_root_node(&mut self, node: N) -> Result<usize, GraphError> {
        match &mut self.state {
            // Corrected: Directly return the result from the inner call.
            GraphState::Dynamic(g) => g.add_root_node(node),
            GraphState::Static(_) => Err(GraphError::GraphIsFrozen),
        }
    }

    /// Clears all nodes and edges from the graph, resetting it to an empty, dynamic state.
    ///
    /// This operation is always successful and will unfreeze the graph if it was frozen.
    fn clear(&mut self) -> Result<(), GraphError> {
        // Clearing the graph resets it to a new, empty, dynamic state,
        // regardless of its previous state. This is a total reset.
        self.state = GraphState::Dynamic(DynamicGraph::new());
        Ok(())
    }
}
