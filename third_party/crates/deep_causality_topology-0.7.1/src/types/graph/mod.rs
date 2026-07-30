/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Graph type for representing simple undirected graphs.

use deep_causality_tensor::CausalTensor;
use std::collections::BTreeMap;

// Submodule declarations (folder-based)
mod api;
mod clone;
mod constructors;
mod display;
mod getters;
mod graph_ops;

mod topology;

// Re-export public API

/// Represents a simple undirected graph (nodes and edges).
///
/// Nodes are represented by `usize` indices.
/// The type parameter T represents metadata associated with each node.
#[derive(Debug, Clone, PartialEq)]
pub struct Graph<T> {
    /// Number of vertices in the graph.
    pub(crate) num_vertices: usize,
    /// Adjacency list: map from vertex index to a list of its neighbors.
    pub(crate) adjacencies: BTreeMap<usize, Vec<usize>>,
    /// Number of edges in the graph.
    pub(crate) num_edges: usize,
    /// Metadata associated with each node.
    pub(crate) data: CausalTensor<T>,
    /// The Focus (Cursor) for Comonadic extraction.
    pub(crate) cursor: usize,
}
