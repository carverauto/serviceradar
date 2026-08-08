/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Clone helpers for MixedGraph.

use crate::MixedGraph;

impl<T> MixedGraph<T> {
    /// Creates a clone of the graph with the cursor reset to `0`.
    ///
    /// Used by the comonadic `extend` to produce per-node focus views.
    pub fn clone_shallow(&self) -> Self
    where
        T: Clone,
    {
        MixedGraph {
            num_vertices: self.num_vertices,
            edges: self.edges.clone(),
            data: self.data.clone(),
            cursor: 0,
        }
    }
}
