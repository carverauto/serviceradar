/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Hypergraph type for representing hypergraph structures.

use deep_causality_sparse::CsrMatrix;
use deep_causality_tensor::CausalTensor;

// Submodule declarations (folder-based)
mod api;
mod clone;
mod constructors;
mod display;
mod getters;

mod topology;

// Re-export public API

/// Represents a hypergraph where hyperedges can connect an arbitrary number of nodes.
///
/// The incidence matrix efficiently stores the relationships.
/// The type parameter T represents metadata associated with each node.
#[derive(Debug, Clone, PartialEq)]
pub struct Hypergraph<T> {
    /// Number of nodes in the hypergraph.
    pub(crate) num_nodes: usize,
    /// Number of hyperedges in the hypergraph.
    pub(crate) num_hyperedges: usize,
    /// Incidence matrix: rows represent nodes, columns represent hyperedges.
    pub(crate) incidence: CsrMatrix<i8>,
    /// Metadata associated with each node.
    pub(crate) data: CausalTensor<T>,
    /// The Focus (Cursor) for Comonadic extraction.
    pub(crate) cursor: usize,
}

impl<T> Hypergraph<T> {
    /// Returns the current cursor position.
    pub fn cursor(&self) -> usize {
        self.cursor
    }
}
