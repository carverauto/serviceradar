/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Freezable, GraphState, GraphView, UltraGraphContainer, Unfreezable};

impl<N: Clone, W: Clone> UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Ensures the graph is in the immutable, performance-optimized `Static` state.
    ///
    /// If the graph is already frozen, this operation is a no-op. Otherwise, it
    /// converts the graph from a `Dynamic` state in-place. This is an O(V + E)
    /// operation if a state change occurs.
    pub fn freeze(&mut self) {
        if !self.is_frozen() {
            // Safely take ownership of the state, leaving a default in its place.
            let current_state = std::mem::take(&mut self.state);

            // We know this will be the `Dynamic` variant because of the check above.
            if let GraphState::Dynamic(dynamic_graph) = current_state {
                // Consume the dynamic graph to create the new static one.
                self.state = GraphState::Static(dynamic_graph.freeze());
            }
            // The `else` arm is unreachable in a single-threaded context.
        }
        // If it's already static, do nothing.
    }

    /// Ensures the graph is in the mutable, `Dynamic` state.
    ///
    /// If the graph is already dynamic, this operation is a no-op. Otherwise, it
    /// converts the graph from a `Static` state in-place. This is an O(V + E)
    /// operation if a state change occurs and requires node and edge data to be `Clone`.
    pub fn unfreeze(&mut self) {
        if self.is_frozen() {
            // Safely take ownership of the state.
            let current_state = std::mem::take(&mut self.state);

            // We know this will be the `Static` variant because of the check above.
            if let GraphState::Static(static_graph) = current_state {
                // Consume the static graph to create the new dynamic one.
                // This inner `unfreeze` call is infallible.
                self.state = GraphState::Dynamic(static_graph.unfreeze());
            }
            // The `else` arm is unreachable.
        }
        // If it's already dynamic, do nothing.
    }
}
