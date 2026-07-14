/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GraphError, GraphView};

pub trait PathfindingGraphAlgorithms<N, W>: GraphView<N, W> {
    /// Checks if a path of any length exists from a start to a stop index.
    fn is_reachable(&self, start_index: usize, stop_index: usize) -> Result<bool, GraphError>;

    /// Returns the length of the shortest path (in number of nodes) from a start to a stop index.
    fn shortest_path_len(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Option<usize>, GraphError>;

    /// Finds the complete shortest path from a start to a stop index.
    fn shortest_path(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Option<Vec<usize>>, GraphError>;

    /// Finds the shortest path in a weighted graph using Dijkstra's algorithm.
    fn shortest_weighted_path(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Option<(Vec<usize>, W)>, GraphError>
    where
        W: Copy + Ord + Default + std::ops::Add<Output = W>;
}
