/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::TopologyError;
use crate::traits::chain_complex::ChainComplex;
use deep_causality_algebra::RealField;
use deep_causality_sparse::CsrMatrix;
use std::borrow::Cow;

/// Capability trait for metric types that can vend a discrete Hodge star operator.
///
/// The Hodge ⋆ on a finite chain complex is the metric-dependent isomorphism between
/// k-forms and (n−k)-forms whose entries are diagonal `dual / primal` cell-volume
/// ratios. It is required by every Hodge-dependent differential operator on
/// `Manifold<K, R>` (`hodge_star`, `codifferential`, `laplacian`).
///
/// # Why an associated `Complex` type
///
/// Each metric implementation pairs naturally with one concrete chain-complex type:
/// `ReggeGeometry<R>` only vends the Hodge ⋆ of a `SimplicialComplex<R>` (it reads
/// from that complex's cached `hodge_star_operators` field); `CubicalReggeGeometry<D,
/// R, S>` only vends the Hodge ⋆ of a `LatticeComplex<D, R>` (it computes the diagonal
/// entries on demand from per-cell volume data). The associated type encodes the
/// pairing and lets `Manifold` express its bound as `K::Metric: HasHodgeStar<R,
/// Complex = K>` — the exact constraint required for the generic differential
/// operators to compile against both backends.
///
/// # Why `Cow<'_, CsrMatrix<R>>`
///
/// Mirrors [`ChainComplex::boundary_matrix`] and [`ChainComplex::coboundary_matrix`].
/// Cache-rich implementors (the simplicial backend) vend `Cow::Borrowed` against the
/// existing precomputed matrices, zero copy. Compute-on-demand implementors (the
/// cubical backend) vend `Cow::Owned` since the diagonal Hodge ⋆ is built once per
/// call from the per-cell volume data. The shape composes with the existing sparse
/// algebra used by `codifferential` and `laplacian`.
///
/// # Static dispatch
///
/// All call sites resolve statically through the `K::Metric: HasHodgeStar<R, Complex
/// = K>` bound. No trait objects, no `dyn`; see `AGENTS.md` "Static Dispatch".
pub trait HasHodgeStar<R: RealField> {
    /// The concrete chain-complex type whose Hodge ⋆ this metric can vend.
    type Complex: ChainComplex;

    /// Return the Hodge ⋆ on grade-`k` forms as a sparse matrix.
    ///
    /// Rows correspond to (n − k)-cells of `complex`; columns to k-cells. Diagonal
    /// entries are the dual / primal cell-volume ratios.
    ///
    /// Cache-rich implementors return `Cow::Borrowed` (zero copy). Compute-on-demand
    /// implementors return `Cow::Owned`.
    ///
    /// # Errors
    ///
    /// Returns `Err(TopologyError::PointCloudError(_))` when the underlying
    /// complex has degenerate geometry (zero-volume top simplex on the
    /// simplicial backend). The cubical backend's computation never fails for
    /// well-formed cell volumes and always returns `Ok`.
    fn hodge_star_matrix<'a>(
        &'a self,
        complex: &'a Self::Complex,
        k: usize,
    ) -> Result<Cow<'a, CsrMatrix<R>>, TopologyError>;

    /// Per-axis uniform edge lengths, when the metric is axis-uniform and
    /// positive-definite (Euclidean signature); `None` otherwise.
    ///
    /// Defaults to `None`. The cubical geometry overrides it for its
    /// unit/uniform/per-axis representations; the spectral grade-0 Poisson
    /// fast path consumes it to build the lattice Laplacian eigenvalues
    /// `λ_k = Σ_d (2 − 2·cos(2π·k_d/N_d)) / h_d²`. Per-edge geometries and
    /// Lorentzian signatures return `None` (the Laplacian is not a
    /// convolution there), which keeps those paths on CG.
    fn uniform_axis_spacings(&self) -> Option<Vec<R>> {
        None
    }
}
