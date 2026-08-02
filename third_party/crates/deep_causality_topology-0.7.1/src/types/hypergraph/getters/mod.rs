/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Getter methods for Hypergraph.

use crate::Hypergraph;
use deep_causality_sparse::CsrMatrix;
use deep_causality_tensor::CausalTensor;

impl<T> Hypergraph<T> {
    /// Returns the number of nodes in the hypergraph.
    pub fn num_nodes(&self) -> usize {
        self.num_nodes
    }

    /// Returns the number of hyperedges in the hypergraph.
    pub fn num_hyperedges(&self) -> usize {
        self.num_hyperedges
    }

    /// Returns a reference to the incidence matrix.
    pub fn incidence(&self) -> &CsrMatrix<i8> {
        &self.incidence
    }

    /// Returns a reference to the data tensor.
    pub fn data(&self) -> &CausalTensor<T> {
        &self.data
    }
}
