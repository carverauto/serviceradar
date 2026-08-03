/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Boundary operator API for SimplicialComplex.

use crate::{SimplicialComplex, TopologyError};
use deep_causality_sparse::CsrMatrix;

impl<T> SimplicialComplex<T> {
    /// Returns the boundary operator ∂ for dimension k.
    ///
    /// The boundary operator maps (k)-chains to (k-1)-chains.
    ///
    /// # Arguments
    /// * `k` - Dimension of the simplices
    ///
    /// # Returns
    /// Reference to the boundary matrix or error if dimension is invalid.
    pub fn boundary_operator(&self, k: usize) -> Result<&CsrMatrix<i8>, TopologyError> {
        self.boundary_operator_impl(k)
    }

    /// Returns the coboundary operator δ for dimension k.
    ///
    /// The coboundary operator maps (k)-chains to (k+1)-chains.
    ///
    /// # Arguments
    /// * `k` - Dimension of the simplices
    ///
    /// # Returns
    /// Reference to the coboundary matrix or error if dimension is invalid.
    pub fn coboundary_operator(&self, k: usize) -> Result<&CsrMatrix<i8>, TopologyError> {
        self.coboundary_operator_impl(k)
    }
}
