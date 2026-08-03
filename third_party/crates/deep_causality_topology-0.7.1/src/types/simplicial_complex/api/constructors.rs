/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Constructor API for SimplicialComplex.

use crate::{SimplicialComplex, Skeleton};
use deep_causality_sparse::CsrMatrix;

impl<T> SimplicialComplex<T> {
    /// Creates a new SimplicialComplex with the given pre-computed Hodge ⋆ operators.
    ///
    /// Use this constructor when the caller has the Hodge ⋆ operators in hand
    /// already (manual fixtures in test code, or scenarios where the operators
    /// come from a non-lumped-mass source). The pre-supplied vector populates
    /// the lazy cache directly; no geometric data is stored, so the accessor
    /// returns the pre-supplied vector unchanged on subsequent reads.
    ///
    /// For the `PointCloud::triangulate` path, use
    /// [`SimplicialComplex::with_geometry`] instead — it defers Hodge ⋆
    /// population to first access and stores coordinates for that build.
    pub fn new(
        skeletons: Vec<Skeleton>,
        boundary_operators: Vec<CsrMatrix<i8>>,
        coboundary_operators: Vec<CsrMatrix<i8>>,
        hodge_star_operators: Vec<CsrMatrix<T>>,
    ) -> Self {
        Self::new_impl(
            skeletons,
            boundary_operators,
            coboundary_operators,
            hodge_star_operators,
        )
    }

    /// Creates a new SimplicialComplex with geometric data for lazy Hodge ⋆
    /// population on first access.
    ///
    /// Hodge ⋆ operators are not built at construction. The first call to
    /// [`SimplicialComplex::hodge_star_operators`] invokes the lumped-mass
    /// build and caches the result. The top-volume degeneracy rejection
    /// surfaces only at that access — TDA-only consumers that never read the
    /// Hodge ⋆ surface succeed on any input geometry.
    pub fn with_geometry(
        skeletons: Vec<Skeleton>,
        boundary_operators: Vec<CsrMatrix<i8>>,
        coboundary_operators: Vec<CsrMatrix<i8>>,
        coords: Vec<T>,
        ambient_dim: usize,
    ) -> Self {
        Self::with_geometry_impl(
            skeletons,
            boundary_operators,
            coboundary_operators,
            coords,
            ambient_dim,
        )
    }
}
