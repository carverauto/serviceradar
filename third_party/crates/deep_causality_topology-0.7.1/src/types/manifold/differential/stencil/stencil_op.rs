/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The compiled linear stage: a CSR-pointer table whose coefficients carry
//! every fold (incidence sign × Hodge factors × transport weights), so one
//! application is a pure gather–multiply–accumulate stream with no column
//! lookups beyond the precompiled `u32` indices and no per-cell index
//! arithmetic.

use deep_causality_algebra::RealField;
use deep_causality_par::MaybeParallel;

#[cfg(feature = "parallel")]
use rayon::prelude::*;

/// Engage the Rayon fan-out only when a pass carries enough fused entries
/// to amortize fork-join; mirrors the operator-loop thresholds established
/// by the perf pass.
#[cfg(feature = "parallel")]
const PAR_STENCIL_THRESHOLD: usize = 1 << 16;

/// A compiled sparse linear operator with folded coefficients.
#[derive(Debug, Clone)]
pub(crate) struct StencilOp<R> {
    rows: usize,
    cols: usize,
    /// Row pointers, `rows + 1` entries.
    ptr: Vec<usize>,
    /// Column indices per entry (`u32`: lattice cell counts fit).
    idx: Vec<u32>,
    /// Folded coefficient per entry.
    coeff: Vec<R>,
}

impl<R> StencilOp<R>
where
    R: RealField + MaybeParallel,
{
    /// Build from per-row entry lists (duplicates already merged).
    pub(crate) fn from_rows(rows_entries: Vec<Vec<(usize, R)>>, cols: usize) -> Self {
        let rows = rows_entries.len();
        let nnz: usize = rows_entries.iter().map(|r| r.len()).sum();
        let mut ptr = Vec::with_capacity(rows + 1);
        let mut idx = Vec::with_capacity(nnz);
        let mut coeff = Vec::with_capacity(nnz);
        ptr.push(0);
        for row in rows_entries {
            for (c, v) in row {
                debug_assert!(c < cols);
                idx.push(c as u32);
                coeff.push(v);
            }
            ptr.push(idx.len());
        }
        Self {
            rows,
            cols,
            ptr,
            idx,
            coeff,
        }
    }

    pub(crate) fn rows(&self) -> usize {
        self.rows
    }

    pub(crate) fn cols(&self) -> usize {
        self.cols
    }

    /// The transposed operator as a fresh gather table (`out[c] =
    /// Σ coeff·input[r]` over the original entries): compiled once so the
    /// adjoint chain streams with the same access pattern and parallel
    /// safety as the forward chain (no scatter).
    pub(crate) fn transpose(&self) -> Self {
        let mut entries: Vec<Vec<(usize, R)>> = vec![Vec::new(); self.cols];
        for r in 0..self.rows {
            for e in self.ptr[r]..self.ptr[r + 1] {
                entries[self.idx[e] as usize].push((r, self.coeff[e]));
            }
        }
        Self::from_rows(entries, self.rows)
    }

    /// `out[r] = Σ coeff·input[idx]` per row. Lengths are the caller's
    /// invariant (validated at the `DecStencilTables` surface).
    pub(crate) fn apply(&self, input: &[R], out: &mut [R]) {
        debug_assert_eq!(input.len(), self.cols);
        debug_assert_eq!(out.len(), self.rows);

        #[cfg(feature = "parallel")]
        if self.coeff.len() >= PAR_STENCIL_THRESHOLD {
            out.par_iter_mut().enumerate().for_each(|(r, o)| {
                let mut acc = R::zero();
                for e in self.ptr[r]..self.ptr[r + 1] {
                    acc += self.coeff[e] * input[self.idx[e] as usize];
                }
                *o = acc;
            });
            return;
        }

        for (r, o) in out.iter_mut().enumerate() {
            let mut acc = R::zero();
            for e in self.ptr[r]..self.ptr[r + 1] {
                acc += self.coeff[e] * input[self.idx[e] as usize];
            }
            *o = acc;
        }
    }
}
