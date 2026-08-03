/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The compiled bilinear stage (the wedge): per output cell, a list of
//! `(ia, ib, coeff)` triples evaluating `Σ coeff · a[ia] · b[ib]`. The
//! triples carry the cup-shuffle signs and the ½ antisymmetrization
//! factor, so the apply is a pure gather–multiply–accumulate.

use deep_causality_algebra::RealField;
use deep_causality_par::MaybeParallel;

#[cfg(feature = "parallel")]
use rayon::prelude::*;

#[cfg(feature = "parallel")]
const PAR_BILINEAR_THRESHOLD: usize = 1 << 16;

/// A compiled bilinear operator over two input cochains.
#[derive(Debug, Clone)]
pub(crate) struct BilinearOp<R> {
    rows: usize,
    cols_a: usize,
    cols_b: usize,
    ptr: Vec<usize>,
    ia: Vec<u32>,
    ib: Vec<u32>,
    coeff: Vec<R>,
}

impl<R> BilinearOp<R>
where
    R: RealField + MaybeParallel,
{
    /// Build from per-row triple lists.
    pub(crate) fn from_rows(
        rows_entries: Vec<Vec<(usize, usize, R)>>,
        cols_a: usize,
        cols_b: usize,
    ) -> Self {
        let rows = rows_entries.len();
        let nnz: usize = rows_entries.iter().map(|r| r.len()).sum();
        let mut ptr = Vec::with_capacity(rows + 1);
        let mut ia = Vec::with_capacity(nnz);
        let mut ib = Vec::with_capacity(nnz);
        let mut coeff = Vec::with_capacity(nnz);
        ptr.push(0);
        for row in rows_entries {
            for (a, b, v) in row {
                debug_assert!(a < cols_a && b < cols_b);
                ia.push(a as u32);
                ib.push(b as u32);
                coeff.push(v);
            }
            ptr.push(ia.len());
        }
        Self {
            rows,
            cols_a,
            cols_b,
            ptr,
            ia,
            ib,
            coeff,
        }
    }

    pub(crate) fn rows(&self) -> usize {
        self.rows
    }

    pub(crate) fn cols_a(&self) -> usize {
        self.cols_a
    }

    pub(crate) fn cols_b(&self) -> usize {
        self.cols_b
    }

    /// The transpose with respect to the `b` operand: at fixed `a`, the
    /// linear map `b ↦ W(a, b)` has matrix `W_a[r, ib] = Σ coeff·a[ia]`;
    /// its transpose `q ↦ W_aᵀ q` is itself a bilinear gather over the
    /// same triples regrouped by `ib` — `out[ib] = Σ coeff·a[ia]·q[r]` —
    /// so [`Self::apply`] serves both directions (`a` stays the first
    /// operand, the original row index becomes the second). Compiled once.
    pub(crate) fn transpose_b(&self) -> Self {
        let mut entries: Vec<Vec<(usize, usize, R)>> = vec![Vec::new(); self.cols_b];
        for r in 0..self.rows {
            for e in self.ptr[r]..self.ptr[r + 1] {
                entries[self.ib[e] as usize].push((self.ia[e] as usize, r, self.coeff[e]));
            }
        }
        Self::from_rows(entries, self.cols_a, self.rows)
    }

    /// `out[r] = Σ coeff · a[ia] · b[ib]` per row.
    pub(crate) fn apply(&self, a: &[R], b: &[R], out: &mut [R]) {
        debug_assert_eq!(a.len(), self.cols_a);
        debug_assert_eq!(b.len(), self.cols_b);
        debug_assert_eq!(out.len(), self.rows);

        #[cfg(feature = "parallel")]
        if self.coeff.len() >= PAR_BILINEAR_THRESHOLD {
            out.par_iter_mut().enumerate().for_each(|(r, o)| {
                let mut acc = R::zero();
                for e in self.ptr[r]..self.ptr[r + 1] {
                    acc += self.coeff[e] * a[self.ia[e] as usize] * b[self.ib[e] as usize];
                }
                *o = acc;
            });
            return;
        }

        for (r, o) in out.iter_mut().enumerate() {
            let mut acc = R::zero();
            for e in self.ptr[r]..self.ptr[r + 1] {
                acc += self.coeff[e] * a[self.ia[e] as usize] * b[self.ib[e] as usize];
            }
            *o = acc;
        }
    }
}
