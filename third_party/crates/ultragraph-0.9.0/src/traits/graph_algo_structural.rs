/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GraphError, GraphView};

pub trait StructuralGraphAlgorithms<N, W>: GraphView<N, W> {
    /// Finds all Strongly Connected Components in the graph.
    fn strongly_connected_components(&self) -> Result<Vec<Vec<usize>>, GraphError>;

    /// Returns the articulation points (cut vertices) of the undirected view of the graph.
    ///
    /// A vertex is an articulation point if removing it (together with its incident
    /// undirected edges) increases the number of connected components. The graph is
    /// interpreted as undirected: every directed edge `(u, v)` contributes the undirected
    /// edge `{u, v}`; self-loops and parallel reverse edges are ignored.
    ///
    /// Vertices are returned in ascending order.
    fn articulation_points(&self) -> Result<Vec<usize>, GraphError>;

    /// Returns the bridges (cut edges) of the undirected view of the graph.
    ///
    /// An undirected edge is a bridge if removing it increases the number of connected
    /// components. Each bridge is reported once as a tuple `(u, v)` with `u < v`. The
    /// returned vector is sorted lexicographically.
    fn bridges(&self) -> Result<Vec<(usize, usize)>, GraphError>;

    /// Returns the biconnected (2-vertex-connected) components of the undirected view.
    ///
    /// Each component is the vertex set of a maximal subgraph that remains connected
    /// after the removal of any single vertex. Articulation points appear in two or
    /// more components; non-articulation vertices appear in exactly one. Isolated
    /// vertices are not included in any component. Vertices within each component are
    /// sorted ascending; component order is deterministic for a given input.
    fn biconnected_components(&self) -> Result<Vec<Vec<usize>>, GraphError>;
}
