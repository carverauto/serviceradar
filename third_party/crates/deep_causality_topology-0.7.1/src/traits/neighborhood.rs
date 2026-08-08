/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Static-dispatch strategy trait for cell-neighborhood queries.
//!
//! `Neighborhood<K>` describes how to enumerate the neighbors of a cell in a complex
//! of type `K: ChainComplex`. Strategies are zero-sized types that monomorphize away;
//! the trait uses a GAT-backed iterator so callers compose them with `extend` /
//! `Manifold::neighbors` without any `dyn` indirection.
//!
//! Concrete strategy implementors live in `types/neighborhood/`:
//!   * `FaceAdjacent`, `CofaceAdjacent` — generic over any `ChainComplex` (defined via ∂ / δ).
//!   * `VonNeumann`, `Moore`, `KRing<const K>` — implemented for `LatticeComplex<D>` only.
//!     Their definitions rely on the regular-grid coordinate structure and Chebyshev
//!     metric, which have no principled simplicial analogue.

use crate::traits::chain_complex::ChainComplex;

/// Stable identifier for a cell within a `ChainComplex`. Returned by `Neighborhood::neighbors`.
///
/// Today this is the linear index of the cell within its skeleton (or grid stratum).
/// Kept as a type alias to allow future evolution (e.g. typed `CellId<K>(usize, PhantomData<K>)`)
/// without breaking the trait surface.
pub type CellId = usize;

/// Strategy for enumerating the neighbors of a cell in a chain complex.
///
/// Implementors are zero-sized types (e.g. `pub struct VonNeumann;`) so passing one
/// to a generic function compiles to nothing. The `Iter<'a>` GAT names the concrete
/// iterator returned by `neighbors`.
pub trait Neighborhood<K: ChainComplex> {
    /// Concrete iterator type yielded by [`Neighborhood::neighbors`].
    type Iter<'a>: Iterator<Item = CellId>
    where
        K: 'a;

    /// Enumerate the neighbors of `cell` in `complex` under this strategy.
    ///
    /// Returns by value (zero allocation for ZSTs); the iterator borrows `complex`
    /// for its lifetime.
    fn neighbors<'a>(&self, complex: &'a K, cell: CellId) -> Self::Iter<'a>;
}
