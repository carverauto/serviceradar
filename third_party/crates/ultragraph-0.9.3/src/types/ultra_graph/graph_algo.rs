/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{
    CentralityGraphAlgorithms, GraphAlgorithms, GraphError, GraphState, PathfindingGraphAlgorithms,
    StructuralGraphAlgorithms, TopologicalGraphAlgorithms, UltraGraphContainer,
};

impl<N, W> GraphAlgorithms<N, W> for UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
}

impl<N, W> CentralityGraphAlgorithms<N, W> for UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Calculates the betweenness centrality of each node in the graph.
    ///
    /// Betweenness centrality measures a node's importance by counting how often it
    /// appears on the shortest paths between all other pairs of nodes. It is a powerful
    /// metric for identifying bottlenecks, bridges, and critical control points in a network.
    ///
    /// ## Time and Space Complexity
    ///
    /// The implementation uses Brandes' algorithm, which is highly efficient.
    ///
    /// * Time Complexity (Unweighted): The cost is dominated by running a BFS from every vertex.
    ///   - O(V * (V + E)), which simplifies to O(V*E) for sparse graphs.
    /// * Time Complexity (Weighted): The cost is dominated by running Dijkstra from every vertex.
    ///   - O(V * (E + V log V)), which simplifies to O(V*E + V² log V).
    /// * Space Complexity: You only need to store the state for one source node s at a time.
    ///   - O(V + E).
    ///
    ///
    /// # Arguments
    ///
    /// * `directed`: If `true`, the calculation considers the graph's edge directions.
    ///   If `false`, all edges are treated as bidirectional.
    /// * `normalized`: If `true`, the centrality scores are normalized by dividing by the
    ///   number of possible pairs of nodes. This allows for comparison between graphs of
    ///   different sizes. If `false`, the raw count of paths is returned.
    ///
    /// # Returns
    ///
    /// A `Result` containing a vector of `(node_index, centrality_score)` tuples.
    /// The centrality score is an `f64` representing the node's importance.
    /// The vector is unsorted.
    fn betweenness_centrality(
        &self,
        directed: bool,
        normalized: bool,
    ) -> Result<Vec<(usize, f64)>, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.betweenness_centrality(directed, normalized),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }

    /// Calculates betweenness centrality across a specific set of critical pathways.
    ///
    /// This function is a highly efficient tool for targeted analysis, such as root cause
    /// investigation or identifying bottlenecks in specific set of graph pathways. Instead of
    /// analyzing all possible paths, it only considers the shortest paths between the
    /// start and end nodes of the pathways you provide.
    ///
    /// ## Time and Space Complexity
    ///
    /// The implementation uses Brandes' algorithm, which is highly efficient.
    ///
    /// * Time Complexity (Unweighted): The cost is dominated by running a BFS from every vertex.
    ///   - O(V * (V + E)), which simplifies to O(V*E) for sparse graphs.
    /// * Time Complexity (Weighted): The cost is dominated by running Dijkstra from every vertex.
    ///   - O(V * (E + V log V)), which simplifies to O(V*E + V² log V).
    /// * Space Complexity: You only need to store the state for one source node s at a time.
    ///   - O(V + E).
    ///
    /// The algorithm correctly routes these paths through the entire graph, ensuring that
    /// the results are accurate even if the shortest path temporarily leaves a conceptual
    /// "subgraph".
    ///
    /// # Arguments
    /// * `pathways`: A slice of `(start_node, end_node)` tuples defining the pathways to analyze.
    /// * `directed`: If `true`, considers edge directions.
    /// * `normalized`: If `true`, normalizes scores by the number of provided pathways.
    ///
    /// # Returns
    /// An unsorted vector of `(node_index, centrality_score)` tuples for nodes that lie on
    /// one or more of the specified pathways.
    ///
    fn pathway_betweenness_centrality(
        &self,
        pathways: &[(usize, usize)],
        directed: bool,
        normalized: bool,
    ) -> Result<Vec<(usize, f64)>, GraphError> {
        match &self.state {
            GraphState::Static(g) => {
                g.pathway_betweenness_centrality(pathways, directed, normalized)
            }
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }
}

impl<N, W> PathfindingGraphAlgorithms<N, W> for UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Checks if a node `stop_index` is reachable from `start_index`.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    /// - Returns an error if either node index is invalid.
    fn is_reachable(&self, start_index: usize, stop_index: usize) -> Result<bool, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.is_reachable(start_index, stop_index),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }

    /// Calculates the length of the shortest path between two nodes.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    /// - Returns an error if either node index is invalid.
    fn shortest_path_len(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Option<usize>, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.shortest_path_len(start_index, stop_index),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }

    /// Finds the shortest path (as a sequence of node indices) between two nodes.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    /// - Returns an error if either node index is invalid.
    fn shortest_path(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Option<Vec<usize>>, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.shortest_path(start_index, stop_index),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }

    /// Finds the shortest path (as a sequence of node indices) between two nodes, considering edge weights.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Type Parameters
    /// - `W`: The weight type, which must implement `Copy`, `Ord`, `Default`, and `std::ops::Add`.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    /// - Returns an error if either node index is invalid.
    /// - Returns an error if the graph contains negative cycles (for algorithms like Dijkstra's).
    fn shortest_weighted_path(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Option<(Vec<usize>, W)>, GraphError>
    where
        W: Copy + Ord + Default + std::ops::Add<Output = W>,
    {
        match &self.state {
            GraphState::Static(g) => g.shortest_weighted_path(start_index, stop_index),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }
}

impl<N, W> StructuralGraphAlgorithms<N, W> for UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Finds the strongly connected components (SCCs) of the graph.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Returns
    /// A `Result` containing a `Vec<Vec<usize>>`, where each inner `Vec<usize>` represents
    /// a strongly connected component as a list of node indices.
    ///
    /// # Errors
    /// Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    fn strongly_connected_components(&self) -> Result<Vec<Vec<usize>>, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.strongly_connected_components(),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }

    /// Returns the articulation points of the undirected view.
    ///
    /// # Preconditions
    /// Only available when the graph is `Static` (frozen).
    ///
    /// # Errors
    /// Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    fn articulation_points(&self) -> Result<Vec<usize>, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.articulation_points(),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }

    /// Returns the bridges of the undirected view.
    ///
    /// # Preconditions
    /// Only available when the graph is `Static` (frozen).
    ///
    /// # Errors
    /// Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    fn bridges(&self) -> Result<Vec<(usize, usize)>, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.bridges(),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }

    /// Returns the biconnected components of the undirected view.
    ///
    /// # Preconditions
    /// Only available when the graph is `Static` (frozen).
    ///
    /// # Errors
    /// Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    fn biconnected_components(&self) -> Result<Vec<Vec<usize>>, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.biconnected_components(),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }
}

impl<N, W> TopologicalGraphAlgorithms<N, W> for UltraGraphContainer<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Finds a cycle in the graph.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Errors
    ///
    /// Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    fn find_cycle(&self) -> Result<Option<Vec<usize>>, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.find_cycle(),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }

    /// Checks if the graph contains a cycle.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Errors
    ///
    /// Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    fn has_cycle(&self) -> Result<bool, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.has_cycle(),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }

    /// Performs a topological sort of the graph's nodes.
    ///
    /// # Preconditions
    /// This high-performance operation is only available when the graph is in a `Static` (frozen) state.
    ///
    /// # Errors
    ///
    /// - Returns `GraphError::GraphNotFrozen` if the graph is in a `Dynamic` state.
    /// - Returns an error from the underlying implementation if the graph contains a cycle.
    fn topological_sort(&self) -> Result<Option<Vec<usize>>, GraphError> {
        match &self.state {
            GraphState::Static(g) => g.topological_sort(),
            GraphState::Dynamic(_) => Err(GraphError::GraphNotFrozen),
        }
    }
}
