/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The naïve O(n²) DFT — the correctness reference.
//!
//! Every fast kernel in this crate is validated against these functions in
//! tests, the same role the naïve DFT plays in RustFFT. The planner never
//! selects them.

use deep_causality_num_complex::Complex;

use crate::traits::fft_scalar::FftScalar;
use crate::utils::complex_ops::{czero, scale};
use crate::utils::twiddles::twiddle;

/// Forward DFT by direct summation: `X_k = Σ_j x_j · e^{-2πi·jk/n}`.
/// Unnormalized, matching the crate's forward contract.
pub fn naive_dft<R: FftScalar>(input: &[Complex<R>]) -> Vec<Complex<R>> {
    let n = input.len();
    let mut out = vec![czero::<R>(); n];
    for (k, out_k) in out.iter_mut().enumerate() {
        let mut acc = czero::<R>();
        for (j, x) in input.iter().enumerate() {
            acc += *x * twiddle::<R>(j * k, n);
        }
        *out_k = acc;
    }
    out
}

/// Inverse DFT by direct summation, scaled by `1/n`:
/// `x_j = (1/n) Σ_k X_k · e^{+2πi·jk/n}`.
pub fn naive_idft<R: FftScalar>(input: &[Complex<R>]) -> Vec<Complex<R>> {
    let n = input.len();
    let mut out = vec![czero::<R>(); n];
    if n == 0 {
        return out;
    }
    let inv_n = R::one() / R::from_usize(n).expect("length is representable");
    for (j, out_j) in out.iter_mut().enumerate() {
        let mut acc = czero::<R>();
        for (k, x) in input.iter().enumerate() {
            // e^{+iθ} is the conjugate twiddle.
            let w = twiddle::<R>(j * k, n);
            acc += *x * Complex::new(w.re, -w.im);
        }
        *out_j = scale(acc, inv_n);
    }
    out
}
