/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! `CofaceAdjacent` — chain-complex-generic coface adjacency.
//!
//! Operates on cells in the **(max_dim − 1)-stratum** (e.g. faces in a 3D mesh, edges
//! in a 2D mesh). For a target (max_dim − 1)-cell ρ, returns the top-stratum cells
//! that contain ρ as a face. Derived purely from `δ_{max_dim − 1}` (the coboundary)
//! so the strategy works on any `ChainComplex`.

use crate::traits::chain_complex::ChainComplex;
use crate::traits::neighborhood::{CellId, Neighborhood};
use std::vec;

/// Coface adjacency: (max_dim)-cells containing the target (max_dim − 1)-cell as a face.
///
/// `CellId` is interpreted as the row index in `δ_{max_dim − 1}` (equivalently, the
/// column index in the (max_dim − 1)-stratum's cell enumeration). The neighborhood
/// of `ρ` is `{ σ : ρ ∈ ∂σ }`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CofaceAdjacent;

/// Concrete iterator returned by `<CofaceAdjacent as Neighborhood<K>>::neighbors`.
pub struct CofaceAdjacentIter {
    inner: vec::IntoIter<CellId>,
}

impl Iterator for CofaceAdjacentIter {
    type Item = CellId;
    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next()
    }
}

impl<K: ChainComplex> Neighborhood<K> for CofaceAdjacent {
    type Iter<'a>
        = CofaceAdjacentIter
    where
        K: 'a;

    #[allow(clippy::needless_range_loop)]
    fn neighbors<'a>(&self, complex: &'a K, cell: CellId) -> Self::Iter<'a> {
        let max_dim = complex.max_dim();
        if max_dim == 0 {
            return CofaceAdjacentIter {
                inner: Vec::new().into_iter(),
            };
        }
        // δ_{max_dim - 1} has shape (num_cells(max_dim), num_cells(max_dim - 1)).
        // Row index of `cell` (an (max_dim - 1)-cell) in δ identifies which top cells
        // contain it as a face — i.e. row entries of column `cell` in δ map to top-cell IDs.
        let coboundary_cow = complex.coboundary_matrix(max_dim - 1);
        let coboundary = &*coboundary_cow;
        let (n_rows, n_cols) = coboundary.shape();
        if cell >= n_cols {
            return CofaceAdjacentIter {
                inner: Vec::new().into_iter(),
            };
        }

        let row_ptr = coboundary.row_indices();
        let col_idx = coboundary.col_indices();

        let mut cofaces: Vec<CellId> = Vec::new();
        for r in 0..n_rows {
            let start = row_ptr[r];
            let end = row_ptr[r + 1];
            for idx in start..end {
                if col_idx[idx] == cell {
                    cofaces.push(r);
                    break;
                }
            }
        }

        cofaces.sort_unstable();
        cofaces.dedup();

        CofaceAdjacentIter {
            inner: cofaces.into_iter(),
        }
    }
}
