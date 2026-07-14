/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{GraphError, GraphView};

pub trait GraphMut<N, W>: GraphView<N, W> {
    fn add_node(&mut self, node: N) -> Result<usize, GraphError>;
    fn update_node(&mut self, index: usize, node: N) -> Result<(), GraphError>;

    fn remove_node(&mut self, index: usize) -> Result<(), GraphError>;

    // Edge Mutation
    fn add_edge(&mut self, a: usize, b: usize, weight: W) -> Result<(), GraphError>;
    fn remove_edge(&mut self, a: usize, b: usize) -> Result<(), GraphError>;

    // Root Node Mutation
    fn add_root_node(&mut self, node: N) -> Result<usize, GraphError>;

    // Graph-wide Mutation
    fn clear(&mut self) -> Result<(), GraphError>;
}
