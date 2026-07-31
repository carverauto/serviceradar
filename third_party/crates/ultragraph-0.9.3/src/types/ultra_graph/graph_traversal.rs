/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GraphError, GraphState, GraphTraversal, UltraGraphContainer};

impl<N, W> GraphTraversal<N, W> for UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Returns an iterator over the indices of all nodes that have an outbound edge from the given node `a`.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    /// - Returns an error if the node at index `a` does not exist.
    fn outbound_edges(&self, a: usize) -> Result<impl Iterator<Item = usize> + '_, GraphError> {
        match &self.state {
            GraphState::Static(g) => {
                // Delegate to the CsmGraph's hyper-optimized implementation.
                g.outbound_edges(a)
            }
            GraphState::Dynamic(_) => {
                // This operation is not supported on a dynamic graph.
                // The graph must be frozen for high-performance traversal.
                Err(GraphError::GraphNotFrozen)
            }
        }
    }
    /// Returns an iterator over the indices of all nodes that have an inbound edge to the given node `a`.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    /// - Returns an error if the node at index `a` does not exist.
    fn inbound_edges(&self, a: usize) -> Result<impl Iterator<Item = usize> + '_, GraphError> {
        match &self.state {
            GraphState::Static(g) => {
                // Delegate to the CsmGraph's hyper-optimized implementation.
                g.inbound_edges(a)
            }
            GraphState::Dynamic(_) => {
                // This operation is not supported on a dynamic graph.
                // The graph must be frozen for high-performance traversal.
                Err(GraphError::GraphNotFrozen)
            }
        }
    }
}
