/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! `FaceAdjacent` — chain-complex-generic face adjacency on top cells.
//!
//! Two top-dimensional cells σ, τ are face-adjacent iff they share a (max_dim − 1)-face.
//! Derived purely from `∂_{max_dim}` so the strategy works on any `ChainComplex`.

use crate::traits::chain_complex::ChainComplex;
use crate::traits::neighborhood::{CellId, Neighborhood};
use std::vec;

/// Face adjacency on top-stratum cells, defined via ∂.
///
/// `CellId` is interpreted as the column index in `∂_{max_dim}`. The neighborhood
/// of `σ` is `{ τ : τ ≠ σ and τ shares a (max_dim − 1)-face with σ }`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FaceAdjacent;

/// Concrete iterator returned by `<FaceAdjacent as Neighborhood<K>>::neighbors`.
pub struct FaceAdjacentIter {
    inner: vec::IntoIter<CellId>,
}

impl Iterator for FaceAdjacentIter {
    type Item = CellId;
    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next()
    }
}

impl<K: ChainComplex> Neighborhood<K> for FaceAdjacent {
    type Iter<'a>
        = FaceAdjacentIter
    where
        K: 'a;

    #[allow(clippy::needless_range_loop)]
    fn neighbors<'a>(&self, complex: &'a K, cell: CellId) -> Self::Iter<'a> {
        let max_dim = complex.max_dim();
        if max_dim == 0 {
            return FaceAdjacentIter {
                inner: Vec::new().into_iter(),
            };
        }
        let boundary_cow = complex.boundary_matrix(max_dim);
        let boundary = &*boundary_cow;
        let (n_rows, n_cols) = boundary.shape();
        if cell >= n_cols {
            return FaceAdjacentIter {
                inner: Vec::new().into_iter(),
            };
        }

        let row_ptr = boundary.row_indices();
        let col_idx = boundary.col_indices();

        // 1) Collect (max_dim − 1)-faces of `cell` (rows where column == cell has nonzero entry).
        let mut faces_of_cell: Vec<usize> = Vec::new();
        for r in 0..n_rows {
            let start = row_ptr[r];
            let end = row_ptr[r + 1];
            for idx in start..end {
                if col_idx[idx] == cell {
                    faces_of_cell.push(r);
                    break;
                }
            }
        }

        // 2) For each shared face, collect other top cells σ' that incident on it.
        let mut neighbors: Vec<CellId> = Vec::new();
        for r in faces_of_cell {
            let start = row_ptr[r];
            let end = row_ptr[r + 1];
            for idx in start..end {
                let other = col_idx[idx];
                if other != cell {
                    neighbors.push(other);
                }
            }
        }

        // 3) Dedupe (a face may be shared, and CSR may repeat).
        neighbors.sort_unstable();
        neighbors.dedup();

        FaceAdjacentIter {
            inner: neighbors.into_iter(),
        }
    }
}
