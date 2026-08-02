/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::cell::Cell;
use deep_causality_sparse::CsrMatrix;
use std::borrow::Cow;

/// Types that form a chain complex (a CW-style cellular decomposition).
/// This generalizes simplicial complexes, cubical lattices, and arbitrary cellular decompositions.
///
/// The trait uses static dispatch end-to-end: cell iteration is exposed via a GAT-backed
/// `CellIter<'_>` and the boundary / coboundary matrices return `Cow<'_, CsrMatrix<i8>>`
/// so cache-rich implementors can vend `Cow::Borrowed` (zero copy) while compute-on-demand
/// implementors return `Cow::Owned`.
pub trait ChainComplex {
    /// The type of cells in this complex.
    type CellType: Cell;

    /// The concrete iterator type returned by `cells`.
    type CellIter<'a>: Iterator<Item = Self::CellType>
    where
        Self: 'a;

    /// The metric type associated with this complex.
    ///
    /// Precision-carrying complexes (e.g. `SimplicialComplex<R: RealField>`,
    /// `LatticeComplex<const D, R: RealField>`) bind this to a concrete metric type
    /// at their own `R`: `type Metric = ReggeGeometry<R>;`, `type Metric =
    /// CubicalReggeGeometry<D, R>;`. The combinatorial `CellComplex<C>` has no metric
    /// and binds `type Metric = ();`. The metric precision flows from the complex's
    /// own type parameters, not from a generic argument on this associated type.
    ///
    /// See `design.md` Decision 1 of `generalize-topology-over-realfield` for the
    /// rationale for picking a plain associated type over a GAT.
    type Metric;

    /// Iterate over all k-cells in the complex.
    fn cells(&self, k: usize) -> Self::CellIter<'_>;

    /// Get the total number of k-cells.
    fn num_cells(&self, k: usize) -> usize;

    /// The maximum dimension of cells in the complex.
    fn max_dim(&self) -> usize;

    /// Return the boundary matrix ∂_k as a sparse matrix.
    /// Rows correspond to (k-1)-cells, columns to k-cells.
    ///
    /// Cache-rich implementors return `Cow::Borrowed`. Compute-on-demand implementors
    /// return `Cow::Owned`.
    fn boundary_matrix(&self, k: usize) -> Cow<'_, CsrMatrix<i8>>;

    /// Return the coboundary matrix δ_k as a sparse matrix.
    /// δ_k is the transpose of ∂_{k+1}.
    ///
    /// Cache-rich implementors return `Cow::Borrowed`. Compute-on-demand implementors
    /// return `Cow::Owned`.
    fn coboundary_matrix(&self, k: usize) -> Cow<'_, CsrMatrix<i8>>;

    /// Compute the k-th Betti number β_k = dim(H_k).
    /// H_k = ker(∂_k) / im(∂_{k+1})
    fn betti_number(&self, k: usize) -> usize;

    /// Layout of a uniform axis-aligned lattice, if this complex is one:
    /// `(shape, periodic)` per axis, in the complex's own axis order.
    ///
    /// Defaults to `None`. The cubical lattice overrides it; the spectral
    /// grade-0 Poisson fast path consumes it to decide whether the
    /// Laplacian diagonalizes under the DFT (it does exactly when every
    /// axis is periodic).
    fn uniform_lattice_layout(&self) -> Option<(Vec<usize>, Vec<bool>)> {
        None
    }
}
