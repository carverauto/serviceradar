/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::storage::graph_state::GraphState;
use crate::{DynamicGraph, UltraGraphContainer};

// This implementation is required for the pattern below.
// The default state of a graph is an empty, dynamic one.
impl<N, W> Default for GraphState<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    fn default() -> Self {
        GraphState::Dynamic(DynamicGraph::new())
    }
}

impl<N, W> Default for UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    fn default() -> Self {
        Self::new()
    }
}
