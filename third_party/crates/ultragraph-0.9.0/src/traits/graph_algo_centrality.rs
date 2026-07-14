/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GraphError, GraphView};

pub trait CentralityGraphAlgorithms<N, W>: GraphView<N, W> {
    /// Calculates the betweenness centrality of each node in the graph.
    fn betweenness_centrality(
        &self,
        directed: bool,
        normalized: bool,
    ) -> Result<Vec<(usize, f64)>, GraphError>;

    /// Calculates betweenness centrality across a specific set of critical pathways.
    fn pathway_betweenness_centrality(
        &self,
        pathways: &[(usize, usize)],
        directed: bool,
        normalized: bool,
    ) -> Result<Vec<(usize, f64)>, GraphError>;
}
