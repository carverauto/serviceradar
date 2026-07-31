/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod default;
mod graph_csm_algo;
mod graph_csm_algo_articulation_points;
mod graph_csm_algo_biconnected_components;
mod graph_csm_algo_bridges;
mod graph_csm_algo_centrality;
mod graph_csm_algo_pathfinder;
mod graph_csm_algo_structural;
mod graph_csm_algo_topological;
mod graph_csm_biconnectivity_common;
mod graph_csm_unfreeze;
mod graph_csm_view;
mod graph_traversal;

// The "Struct of Arrays" (SoA) representation for adjacencies.
// This is now a first-class, albeit private, component of the CsmGraph.
// It derives Default for convenience in constructors.
#[derive(Default, Debug, Clone)]
pub(crate) struct CsrAdjacency<W>
where
    W: Clone + Default,
{
    pub(crate) offsets: Vec<usize>,
    pub(crate) targets: Vec<usize>,
    pub(crate) weights: Vec<W>,
}

#[derive(Clone, Debug)]
pub struct CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    // Node payloads, indexed directly by `usize`.
    nodes: Vec<N>,

    // CsrAdjacency structure for forward traversal (successors).
    // The CsrAdjacency makes the intent of the data layout explicit and clean.
    forward_edges: CsrAdjacency<W>,

    // CSR structure for backward traversal (predecessors).
    backward_edges: CsrAdjacency<W>,

    // Index of the designated root node.
    root_index: Option<usize>,
}

impl<N, W> CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Creates a new, empty `CsmGraph`.
    ///
    /// The graph will have zero nodes and zero edges.
    pub fn new() -> Self {
        Self {
            nodes: Vec::new(),

            // Initialize with a valid empty CSR state. The offsets vector must
            // contain a single `0` to correctly represent the `V + 1` length rule, where V=0.
            forward_edges: CsrAdjacency {
                offsets: vec![0],
                ..Default::default()
            },
            backward_edges: CsrAdjacency {
                offsets: vec![0],
                ..Default::default()
            },
            root_index: None,
        }
    }

    /// Creates a new, empty `DynamicGraph` with pre-allocated capacity.
    ///
    /// This is the most efficient way to start building a graph when the approximate
    /// final size is known, as it can reduce or eliminate memory reallocations
    /// during the `add_node` and `add_edge` process.
    ///
    /// # Arguments
    /// * `num_nodes`: The number of nodes to pre-allocate space for.
    pub fn with_capacity(num_nodes: usize) -> Self {
        Self {
            nodes: Vec::with_capacity(num_nodes),
            // Initialize with a valid empty CSR state. The offsets vector must
            // contain a single `0` to correctly represent the `V + 1` length rule, where V=0.
            forward_edges: CsrAdjacency {
                offsets: vec![0],
                ..Default::default()
            },
            backward_edges: CsrAdjacency {
                offsets: vec![0],
                ..Default::default()
            },
            root_index: None,
        }
    }

    // Internal helper for freeze
    pub(crate) fn construct(
        nodes: Vec<N>,
        forward_edges: CsrAdjacency<W>,
        backward_edges: CsrAdjacency<W>,
        root_index: Option<usize>,
    ) -> Self {
        Self {
            nodes,
            forward_edges,
            backward_edges,
            root_index,
        }
    }
}
