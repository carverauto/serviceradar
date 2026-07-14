/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CsmGraph, DynamicGraph, Unfreezable};
use std::mem;

/// This implementation provides the logic for the "unfreeze" part of the graph's
/// evolutionary lifecycle. It allows a static, high-performance `CsmGraph` to be
/// converted back into a flexible `DynamicGraph`, readying it for a new phase
/// of mutations and evolution.
///
/// # Infallibility and Design
///
/// A key architectural feature of this method is that it is **infallible**—it does
/// not return a `Result`. This is a deliberate design choice based on the
/// following guarantees:
///
/// 1.  **Guaranteed Input Integrity:** The `unfreeze` method consumes `self`, taking
///     ownership of a `CsmGraph`. Within this library's ecosystem, a `CsmGraph`
///     can only be created by the `.freeze()` operation, which guarantees that its
///     internal state (the CSR structures) is always perfectly consistent and valid.
///
/// 2.  **Deterministic Transformation:** The operation is a deterministic data
///     transformation, not a failable action. It deconstructs the highly structured
///     CSR format into the less constrained `Vec<Vec<...>>` adjacency list. Every
///     valid `CsmGraph` has exactly one corresponding `DynamicGraph` representation.
///
/// There are no logical branches in the `unfreeze` process that could result in a
/// user-handleable error. An out-of-bounds access would indicate a critical bug
/// in the `.freeze()` method's construction logic, which would be a `panic`-worthy
/// programmer error, not a runtime failure.
///
/// This infallible signature provides a strong guarantee to the user: transitioning
/// from an analysis state back to an evolutionary state is always a safe and
/// predictable operation.
impl<N, W> Unfreezable<N, W> for CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Consumes the `CsmGraph` and converts it back into a mutable `DynamicGraph`.
    ///
    /// This operation reconstructs the adjacency list representation from the CSR
    /// format by moving data, not cloning it, making it highly efficient.
    fn unfreeze(self) -> DynamicGraph<N, W> {
        let num_nodes = self.nodes.len();

        // Destructure self to gain ownership of its fields. This allows us to
        // mutably access and move data out of the internal vectors.
        let Self {
            nodes,
            mut forward_edges, // We need this to be mutable to `take` from it.
            backward_edges: _, // Not needed for reconstruction, will be dropped.
            root_index,
        } = self;

        // 1. Convert `Vec<N>` into `Vec<Option<N>>` by moving the nodes.
        let dynamic_nodes: Vec<Option<N>> = nodes.into_iter().map(Some).collect();

        // 2. Reconstruct the adjacency list `Vec<Vec<(usize, W)>>` from the CSR format.
        let dynamic_edges: Vec<Vec<(usize, W)>> = (0..num_nodes)
            .map(|i| {
                // Get the slice of neighbors for node `i` using the offsets.
                let start = forward_edges.offsets[i];
                let end = forward_edges.offsets[i + 1];

                // Get a slice of the targets.
                let targets_slice = &forward_edges.targets[start..end];
                // Get a mutable slice of the weights to `take` from.
                let weights_slice = &mut forward_edges.weights[start..end];

                // Zip the target indices with mutable references to the weights.
                targets_slice
                    .iter()
                    .zip(weights_slice.iter_mut())
                    .map(|(&target, weight)| (target, mem::take(weight)))
                    .collect()
            })
            .collect();

        // 3. Construct the new DynamicGraph from its reassembled parts.
        DynamicGraph::construct(dynamic_nodes, dynamic_edges, root_index)
    }
}
