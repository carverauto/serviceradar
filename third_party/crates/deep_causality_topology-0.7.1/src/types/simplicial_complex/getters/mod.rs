/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Getter methods for SimplicialComplex fields.

use crate::types::simplicial_complex::lazy_hodge_star::build_lumped_mass_hodge_star;
use crate::{SimplicialComplex, Skeleton, TopologyError};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_sparse::CsrMatrix;

impl<T> SimplicialComplex<T> {
    /// Returns the total count of all geometric entities (simplices) in the complex.
    pub fn total_simplices(&self) -> usize {
        self.skeletons.iter().map(|s| s.simplices.len()).sum()
    }

    /// Returns the dimension of the highest-order simplex.
    pub fn max_simplex_dimension(&self) -> usize {
        self.skeletons.len().saturating_sub(1)
    }

    /// Returns a reference to all skeletons.
    pub fn skeletons(&self) -> &Vec<Skeleton> {
        &self.skeletons
    }

    /// Returns a reference to all boundary operators.
    pub fn boundary_operators(&self) -> &Vec<CsrMatrix<i8>> {
        &self.boundary_operators
    }

    /// Returns a reference to all coboundary operators.
    pub fn coboundary_operators(&self) -> &Vec<CsrMatrix<i8>> {
        &self.coboundary_operators
    }
}

impl<T> SimplicialComplex<T>
where
    T: RealField + FromPrimitive,
{
    /// Returns the lumped-mass Hodge ⋆ operators, building them lazily on the
    /// first invocation when the complex was constructed via
    /// [`SimplicialComplex::with_geometry`].
    ///
    /// # Errors
    ///
    /// Returns `Err(TopologyError::PointCloudError(msg))` in two cases:
    ///
    /// 1. **Degenerate top simplex.** The complex contains a top-dimensional
    ///    simplex of volume below `T::epsilon() * 100`. The message contains
    ///    the substrings `"top-dimensional simplex"` and `"below tolerance"`.
    /// 2. **No geometric data available.** The complex was constructed via
    ///    [`SimplicialComplex::new`] with an empty Hodge ⋆ vector and no
    ///    coordinates supplied. Lazy build cannot proceed; the caller must
    ///    either supply Hodge ⋆ at construction or build via
    ///    [`SimplicialComplex::with_geometry`].
    ///
    /// Empty complexes (no skeletons) return `Ok(&empty_vec)` without
    /// attempting to build. Once a successful build completes, the result is
    /// cached and subsequent calls return the same borrow without recomputing.
    pub fn hodge_star_operators(&self) -> Result<&Vec<CsrMatrix<T>>, TopologyError> {
        if let Some(cached) = self.hodge_star_operators.get() {
            return Ok(cached);
        }
        if self.skeletons.is_empty() {
            let _ = self.hodge_star_operators.set(Vec::new());
            return Ok(self.hodge_star_operators.get().unwrap());
        }
        let geom = self.geometric_data.as_ref().ok_or_else(|| {
            TopologyError::PointCloudError(
                "hodge_star_operators: geometric data is not available; this complex was constructed without coordinates and without pre-supplied Hodge ⋆ operators".to_string(),
            )
        })?;
        let ops = build_lumped_mass_hodge_star(&self.skeletons, &geom.coords, geom.ambient_dim)?;
        let _ = self.hodge_star_operators.set(ops);
        Ok(self.hodge_star_operators.get().unwrap())
    }
}
