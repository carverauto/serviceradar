/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of boundary operators for SimplicialComplex.

use crate::{SimplicialComplex, TopologyError};
use deep_causality_sparse::CsrMatrix;

impl<T> SimplicialComplex<T> {
    /// CPU implementation: returns boundary operator for dimension k.
    pub(crate) fn boundary_operator_impl(&self, k: usize) -> Result<&CsrMatrix<i8>, TopologyError> {
        if k == 0 {
            return Err(TopologyError::DimensionMismatch(
                "Cannot get boundary operator for dimension 0".to_string(),
            ));
        }

        self.boundary_operators.get(k - 1).ok_or_else(|| {
            TopologyError::DimensionMismatch(format!("No boundary operator for dimension {}", k))
        })
    }

    /// CPU implementation: returns coboundary operator for dimension k.
    pub(crate) fn coboundary_operator_impl(
        &self,
        k: usize,
    ) -> Result<&CsrMatrix<i8>, TopologyError> {
        self.coboundary_operators.get(k).ok_or_else(|| {
            TopologyError::DimensionMismatch(format!("No coboundary operator for dimension {}", k))
        })
    }
}
