/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{GraphError, GraphView};

pub trait GraphTraversal<N, W>: GraphView<N, W> {
    // --- Traversal ---

    /// Returns a non-allocating iterator over the direct successors (outgoing edges) of node `a`.
    fn outbound_edges(&self, a: usize) -> Result<impl Iterator<Item = usize> + '_, GraphError>;

    /// Returns a non-allocating iterator over the direct predecessors (incoming edges) of node `a`.
    fn inbound_edges(&self, a: usize) -> Result<impl Iterator<Item = usize> + '_, GraphError>;
}
