/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CsmGraph, GraphError, GraphTraversal, GraphView};

impl<N, W> GraphTraversal<N, W> for CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Returns a non-allocating iterator over the direct successors (outgoing edges) of node `a`.
    ///
    /// This is a zero-cost operation that provides a direct, read-only view into the
    /// graph's underlying memory, which is a major performance benefit of the CSR format.
    ///
    /// # Errors
    /// Returns `GraphError::NodeNotFound` if the node index `a` is out of bounds.
    fn outbound_edges(&self, a: usize) -> Result<impl Iterator<Item = usize> + '_, GraphError> {
        if !self.contains_node(a) {
            return Err(GraphError::NodeNotFound(a));
        }

        // Get the slice of neighbors for node `a` from the CSR structure.
        let start = self.forward_edges.offsets[a];
        let end = self.forward_edges.offsets[a + 1];

        // The slice is taken from the dedicated `targets` vector.
        let targets_slice = &self.forward_edges.targets[start..end];

        // Return a copied iterator over the slice. This is extremely fast as it
        // involves no new allocations and simply iterates over contiguous memory.
        Ok(targets_slice.iter().copied())
    }

    /// Returns a non-allocating iterator over the direct predecessors (incoming edges) of node `a`.
    ///
    /// # Errors
    /// Returns `GraphError::NodeNotFound` if the node index `a` is out of bounds.
    fn inbound_edges(&self, a: usize) -> Result<impl Iterator<Item = usize> + '_, GraphError> {
        if !self.contains_node(a) {
            return Err(GraphError::NodeNotFound(a));
        }

        // Use the backward_edges structure for efficient inbound traversal.
        let start = self.backward_edges.offsets[a];
        let end = self.backward_edges.offsets[a + 1];

        // Get a slice of the source nodes that point to `a`.
        let targets_slice = &self.backward_edges.targets[start..end];

        // Return the same zero-cost iterator.
        Ok(targets_slice.iter().copied())
    }
}
