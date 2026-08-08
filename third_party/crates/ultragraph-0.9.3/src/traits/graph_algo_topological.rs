/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GraphError, GraphView};

pub trait TopologicalGraphAlgorithms<N, W>: GraphView<N, W> {
    /// Finds a single cycle in the graph and returns the path of nodes that form it.
    fn find_cycle(&self) -> Result<Option<Vec<usize>>, GraphError>;

    /// Checks if the graph contains any directed cycles.
    /// This method should be implemented as a simple call to `self.find_cycle().is_some()`.
    fn has_cycle(&self) -> Result<bool, GraphError>;

    /// Computes a topological sort of the graph, if it is a Directed Acyclic Graph (DAG).
    /// Returns `None` if the graph contains a cycle.
    fn topological_sort(&self) -> Result<Option<Vec<usize>>, GraphError>;
}
