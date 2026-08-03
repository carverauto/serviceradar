/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! SimplicialComplex type for representing simplicial structures.

use crate::Skeleton;
use deep_causality_sparse::CsrMatrix;
use std::sync::OnceLock;

// Submodule declarations (folder-based)
mod api;
mod boundary;
mod builder;
mod constructors;
mod display;
mod getters;
pub(crate) mod lazy_hodge_star;

mod ops;
mod topology;

// Re-export public API
pub use builder::SimplicialComplexBuilder;

/// Geometric data attached to a simplicial complex for lazy Hodge ⋆ population.
///
/// Stored only when the complex is built via [`SimplicialComplex::with_geometry`].
/// Complexes constructed via the legacy `SimplicialComplex::new(...)` path
/// (which pre-supplies the Hodge ⋆ vector) carry `None` here.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct GeometricData<T> {
    pub(crate) coords: Vec<T>,
    pub(crate) ambient_dim: usize,
}

/// A simplicial complex representing a geometric structure.
///
/// Contains skeletons (vertices, edges, faces, etc.) and the associated
/// boundary, coboundary, and Hodge star operators. The Hodge ⋆ vector is
/// populated lazily on first access via
/// [`SimplicialComplex::hodge_star_operators`]; complexes built via
/// [`SimplicialComplex::with_geometry`] carry the coordinates needed for that
/// lazy build, while complexes built via the legacy
/// [`SimplicialComplex::new`] pre-populate the Hodge ⋆ vector directly.
#[derive(Debug)]
pub struct SimplicialComplex<T> {
    /// Storage of geometric entities (Points, Lines, Triangles...)
    pub(crate) skeletons: Vec<Skeleton>,
    /// The Boundary Operators (∂).
    pub(crate) boundary_operators: Vec<CsrMatrix<i8>>,
    /// The Coboundary / Adjacency Cache.
    pub(crate) coboundary_operators: Vec<CsrMatrix<i8>>,
    /// The Hodge Star Operators (⋆). Populated lazily on first access when
    /// `geometric_data` is `Some`; pre-populated at construction otherwise.
    pub(crate) hodge_star_operators: OnceLock<Vec<CsrMatrix<T>>>,
    /// Coordinates + ambient dimension for lazy Hodge ⋆ rebuild. `None` when
    /// the complex was constructed via the legacy `new(...)` path with a
    /// pre-supplied Hodge ⋆ vector.
    pub(crate) geometric_data: Option<GeometricData<T>>,
}

impl<T> SimplicialComplex<T> {
    /// Maps the underlying scalar type of the SimplicialComplex to a new type U.
    ///
    /// Transforms `hodge_star_operators: OnceLock<Vec<CsrMatrix<T>>>` to
    /// `OnceLock<Vec<CsrMatrix<U>>>` (only when initialized) and the optional
    /// `geometric_data` coordinates through the same closure. The structural
    /// components (skeletons, boundary operators) remain unchanged.
    pub fn map<U, F>(self, mut f: F) -> SimplicialComplex<U>
    where
        F: FnMut(T) -> U,
    {
        let new_hodge_cell: OnceLock<Vec<CsrMatrix<U>>> = OnceLock::new();
        if let Some(hodge_ops) = self.hodge_star_operators.into_inner() {
            let mapped: Vec<CsrMatrix<U>> = hodge_ops
                .into_iter()
                // Structure (indices, shape) is preserved; only the stored values are remapped.
                .map(|op| op.map_values(&mut f))
                .collect();
            let _ = new_hodge_cell.set(mapped);
        }

        let new_geom = self.geometric_data.map(|gd| GeometricData {
            coords: gd.coords.into_iter().map(&mut f).collect(),
            ambient_dim: gd.ambient_dim,
        });

        SimplicialComplex {
            skeletons: self.skeletons,
            boundary_operators: self.boundary_operators,
            coboundary_operators: self.coboundary_operators,
            hodge_star_operators: new_hodge_cell,
            geometric_data: new_geom,
        }
    }
}

impl<T: Clone> Clone for SimplicialComplex<T> {
    fn clone(&self) -> Self {
        let new_hodge_cell: OnceLock<Vec<CsrMatrix<T>>> = OnceLock::new();
        if let Some(hodge_ops) = self.hodge_star_operators.get() {
            let _ = new_hodge_cell.set(hodge_ops.clone());
        }
        Self {
            skeletons: self.skeletons.clone(),
            boundary_operators: self.boundary_operators.clone(),
            coboundary_operators: self.coboundary_operators.clone(),
            hodge_star_operators: new_hodge_cell,
            geometric_data: self.geometric_data.clone(),
        }
    }
}

impl<T: PartialEq> PartialEq for SimplicialComplex<T> {
    /// Equality is logical-structure equality across skeletons, boundary
    /// operators, coboundary operators, and geometric data. The Hodge ⋆ cache
    /// is ignored because lazy compute is deterministic; two complexes with
    /// the same logical inputs produce the same Hodge ⋆ regardless of cache
    /// population state.
    fn eq(&self, other: &Self) -> bool {
        self.skeletons == other.skeletons
            && self.boundary_operators == other.boundary_operators
            && self.coboundary_operators == other.coboundary_operators
            && self.geometric_data == other.geometric_data
    }
}

impl<T> Default for SimplicialComplex<T> {
    fn default() -> Self {
        Self {
            skeletons: Vec::new(),
            boundary_operators: Vec::new(),
            coboundary_operators: Vec::new(),
            hodge_star_operators: OnceLock::new(),
            geometric_data: None,
        }
    }
}
