/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of SimplicialComplex constructors.

use crate::types::simplicial_complex::GeometricData;
use crate::{SimplicialComplex, Skeleton};
use deep_causality_sparse::CsrMatrix;
use std::sync::OnceLock;

impl<T> SimplicialComplex<T> {
    /// CPU implementation for the pre-populated Hodge ⋆ path.
    pub(crate) fn new_impl(
        skeletons: Vec<Skeleton>,
        boundary_operators: Vec<CsrMatrix<i8>>,
        coboundary_operators: Vec<CsrMatrix<i8>>,
        hodge_star_operators: Vec<CsrMatrix<T>>,
    ) -> Self {
        let cell: OnceLock<Vec<CsrMatrix<T>>> = OnceLock::new();
        if !hodge_star_operators.is_empty() {
            let _ = cell.set(hodge_star_operators);
        }
        Self {
            skeletons,
            boundary_operators,
            coboundary_operators,
            hodge_star_operators: cell,
            geometric_data: None,
        }
    }

    /// CPU implementation for the lazy-Hodge-⋆ path. Stores coordinates and
    /// ambient dimension; the Hodge ⋆ vector is built on first access.
    pub(crate) fn with_geometry_impl(
        skeletons: Vec<Skeleton>,
        boundary_operators: Vec<CsrMatrix<i8>>,
        coboundary_operators: Vec<CsrMatrix<i8>>,
        coords: Vec<T>,
        ambient_dim: usize,
    ) -> Self {
        Self {
            skeletons,
            boundary_operators,
            coboundary_operators,
            hodge_star_operators: OnceLock::new(),
            geometric_data: Some(GeometricData {
                coords,
                ambient_dim,
            }),
        }
    }
}
