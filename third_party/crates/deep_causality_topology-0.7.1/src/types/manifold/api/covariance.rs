/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Public covariance analysis API for Manifold.
use crate::{Manifold, SimplicialComplex, TopologyError};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;

impl<C, D> Manifold<SimplicialComplex<C>, D>
where
    C: RealField,
    D: RealField + FromPrimitive,
{
    /// Computes the covariance matrix of the field data.
    ///
    /// # Returns
    /// * `Ok(Vec<Vec<D>>)` - The covariance matrix in field precision `D`.
    /// * `Err(TopologyError)` - If data is empty or computation fails
    pub fn covariance_matrix(&self) -> Result<Vec<Vec<D>>, TopologyError> {
        self.covariance_matrix_impl()
    }

    /// Computes eigenvalues of the covariance matrix for field analysis.
    ///
    /// # Returns
    /// * `Ok(Vec<D>)` - Eigenvalues in field precision, sorted in descending order.
    /// * `Err(TopologyError)` - If computation fails
    pub fn eigen_covariance(&self) -> Result<Vec<D>, TopologyError> {
        self.eigen_covariance_impl()
    }
}
