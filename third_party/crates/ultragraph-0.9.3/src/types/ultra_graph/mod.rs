/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#![forbid(unsafe_code)]

use crate::{DynamicGraph, GraphState};

mod default;
mod graph_algo;
mod graph_evolve;
mod graph_mut;
mod graph_traversal;
mod graph_view;

pub type UltraGraph<T> = UltraGraphContainer<T, ()>;
pub type UltraGraphWeighted<T, W> = UltraGraphContainer<T, W>;

#[derive(Clone, Debug)]
pub struct UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    state: GraphState<N, W>,
}

// Constructors

impl<N, W> UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    pub fn new() -> Self {
        Self {
            state: GraphState::Dynamic(DynamicGraph::new()),
        }
    }

    pub fn with_capacity(nodes: usize, edges: Option<usize>) -> Self {
        Self {
            state: GraphState::Dynamic(DynamicGraph::with_capacity(nodes, edges)),
        }
    }
}
