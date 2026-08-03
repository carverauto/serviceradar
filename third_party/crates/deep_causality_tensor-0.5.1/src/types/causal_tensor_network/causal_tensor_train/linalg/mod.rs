/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Small dense linear-algebra helpers shared by the tensor-train operations.
//!
//! These work on flat row-major buffers with explicit dimensions and are bound only on `Scalar`
//! (no `Default`), so they stay valid for the dual-number scalar — unlike `CausalTensor::matmul`,
//! which requires `Default`.

use deep_causality_algebra::ConjugateScalar;

/// Row-major matrix product: `a` (`m × k`) times `b` (`k × n`) into an `m × n` buffer.
pub(crate) fn matmul<T: ConjugateScalar>(a: &[T], m: usize, k: usize, b: &[T], n: usize) -> Vec<T> {
    let mut out = vec![T::zero(); m * n];
    for i in 0..m {
        for p in 0..k {
            let aip = a[i * k + p];
            if aip == T::zero() {
                continue;
            }
            let b_row = &b[p * n..p * n + n];
            let out_row = &mut out[i * n..i * n + n];
            for (o, &bpj) in out_row.iter_mut().zip(b_row.iter()) {
                *o += aip * bpj;
            }
        }
    }
    out
}

/// Transposes a row-major `rows × cols` buffer into `cols × rows`.
pub(crate) fn transpose<T: ConjugateScalar>(a: &[T], rows: usize, cols: usize) -> Vec<T> {
    let mut out = vec![T::zero(); rows * cols];
    for i in 0..rows {
        for j in 0..cols {
            out[j * rows + i] = a[i * cols + j];
        }
    }
    out
}
