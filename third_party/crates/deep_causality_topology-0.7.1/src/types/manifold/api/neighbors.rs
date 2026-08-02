/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Public neighborhood-query API for `Manifold<K, F>`.
//!
//! Delegates to a user-chosen `Neighborhood<K>` strategy at the point of use, so a
//! comonadic `extend` closure can mix-and-match Von Neumann / Moore / KRing / face-
//! adjacent etc. without baking the choice into the manifold's type.

use crate::Manifold;
use crate::traits::chain_complex::ChainComplex;
use crate::traits::neighborhood::{CellId, Neighborhood};

impl<K: ChainComplex, F> Manifold<K, F> {
    /// Enumerate the neighbors of `cell` under the given strategy.
    ///
    /// The strategy `n` is a zero-sized type (e.g. `VonNeumann`, `Moore`, `FaceAdjacent`),
    /// passed by value so the call monomorphizes with no allocation.
    pub fn neighbors<N>(&self, n: N, cell: CellId) -> N::Iter<'_>
    where
        N: Neighborhood<K>,
    {
        n.neighbors(&self.complex, cell)
    }
}
