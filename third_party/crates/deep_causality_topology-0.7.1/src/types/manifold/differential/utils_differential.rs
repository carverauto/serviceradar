/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::chain_complex::ChainComplex;
use crate::types::manifold::Manifold;
use core::ops::Mul;
use deep_causality_algebra::{Field, RealField};
use deep_causality_par::MaybeParallel;

#[cfg(feature = "parallel")]
use rayon::prelude::*;

/// Minimum row count before a matvec fans out over Rayon. A CSR row here
/// is a handful of multiply-adds (memory-bound), so the fork-join cost of
/// a parallel dispatch per CG iteration only pays at large systems —
/// measured on the DEC solver, matvecs through 32³ lattices (~100k rows)
/// still run faster serially; the cutoff engages at 64³-scale grids and
/// above.
#[cfg(feature = "parallel")]
pub(super) const PAR_MATVEC_THRESHOLD: usize = 1 << 18;

impl<K, D> Manifold<K, D>
where
    K: ChainComplex,
    D: RealField + MaybeParallel + Default + PartialEq,
{
    /// Extract the slice of data corresponding to grade-k forms from the flat
    /// per-grade storage carried by `self.data`. Generic over the chain complex
    /// backend via `ChainComplex::num_cells`.
    pub(super) fn get_k_form_data(&self, k: usize) -> Vec<D> {
        let max_dim = self.complex.max_dim();

        let mut offset = 0usize;
        for i in 0..k {
            if i <= max_dim {
                offset += self.complex.num_cells(i);
            }
        }

        let size = if k <= max_dim {
            self.complex.num_cells(k)
        } else {
            0
        };

        if offset + size <= self.data().len() {
            self.data().as_slice()[offset..offset + size].to_vec()
        } else {
            // Graceful degradation: return zeros if data is missing/mismatched.
            vec![D::zero(); size]
        }
    }
}

/// Helper to apply a sparse matrix operator to a vector. Rows are
/// independent, so under the `parallel` feature the matvec fans out over
/// Rayon — this is the inner kernel of every CG iteration.
pub(super) fn apply_operator<D>(matrix: &deep_causality_sparse::CsrMatrix<i8>, data: &[D]) -> Vec<D>
where
    D: Field + Copy + core::ops::Neg<Output = D> + MaybeParallel,
{
    let (rows, cols) = matrix.shape();

    if cols != data.len() {
        // Dimension mismatch, return zeros
        return vec![D::zero(); rows];
    }

    let per_row = |row: usize| {
        let row_start = matrix.row_indices()[row];
        let row_end = matrix.row_indices()[row + 1];
        let mut acc = D::zero();

        for idx in row_start..row_end {
            let col = matrix.col_indices()[idx];
            let val = matrix.values()[idx];

            // Convert i8 to D
            let coeff = if val == 0 {
                D::zero()
            } else if val > 0 {
                D::one()
            } else {
                D::zero() - D::one() // -1
            };

            acc = acc + (coeff * data[col]);
        }
        acc
    };

    #[cfg(feature = "parallel")]
    if rows >= PAR_MATVEC_THRESHOLD {
        return (0..rows).into_par_iter().map(per_row).collect();
    }
    (0..rows).map(per_row).collect()
}

/// Helper to apply a sparse matrix operator with C values to a vector of D.
/// Row-parallel under the `parallel` feature, as [`apply_operator`].
pub(super) fn apply_metric_operator<C, D>(
    matrix: &deep_causality_sparse::CsrMatrix<C>,
    data: &[D],
) -> Vec<D>
where
    C: Copy + MaybeParallel,
    D: Field + Copy + Mul<C, Output = D> + MaybeParallel,
{
    let (rows, cols) = matrix.shape();

    if cols != data.len() {
        // Dimension mismatch, return zeros
        return vec![D::zero(); rows];
    }

    let per_row = |row: usize| {
        let row_start = matrix.row_indices()[row];
        let row_end = matrix.row_indices()[row + 1];
        let mut acc = D::zero();

        for idx in row_start..row_end {
            let col = matrix.col_indices()[idx];
            let val = matrix.values()[idx];

            acc = acc + (data[col] * val);
        }
        acc
    };

    #[cfg(feature = "parallel")]
    if rows >= PAR_MATVEC_THRESHOLD {
        return (0..rows).into_par_iter().map(per_row).collect();
    }
    (0..rows).map(per_row).collect()
}
