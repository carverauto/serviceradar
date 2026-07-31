/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub use crate::traits::graph_algo_centrality::*;
pub use crate::traits::graph_algo_pathfinder::*;
pub use crate::traits::graph_algo_structural::*;
pub use crate::traits::graph_algo_topological::*;

/// A comprehensive suite of graph algorithms.
///
/// This trait aggregates several focused algorithm traits into a single, convenient
/// supertrait. A type that implements `GraphAlgorithms` has access to all methods
/// from the component traits.
pub trait GraphAlgorithms<N, W>:
    TopologicalGraphAlgorithms<N, W>
    + PathfindingGraphAlgorithms<N, W>
    + StructuralGraphAlgorithms<N, W>
    + CentralityGraphAlgorithms<N, W>
{
}
