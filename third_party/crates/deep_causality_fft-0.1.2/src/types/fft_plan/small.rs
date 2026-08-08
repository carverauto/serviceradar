/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Hardcoded kernels for small power-of-two lengths (1–32).
//!
//! These are the planner's base cases: in-place, scratch-free,
//! fixed-trip-count code over stack arrays, in the spirit of the codelet
//! small-N kernels production FFT libraries lean on. Lengths 2 and 4 are
//! twiddle-free straight-line butterflies; 8, 16, and 32 are one
//! decimation-in-time split over the next-smaller kernel with a
//! precomputed twiddle row.

use deep_causality_num_complex::Complex;

use crate::traits::fft_scalar::FftScalar;
use crate::utils::complex_ops::{czero, mul_i, mul_neg_i};
use crate::utils::twiddles::twiddle;

/// Precomputed state for one small length (2, 4, 8, 16, or 32).
#[derive(Debug, Clone)]
pub(crate) struct SmallKernel<R: FftScalar> {
    n: usize,
    /// `W_8^1`; `W_8^2 = −i` and `W_8^3 = −i·W_8^1` are derived in place.
    w8: Complex<R>,
    /// `W_16^k`, `k < 8`.
    tw16: Vec<Complex<R>>,
    /// `W_32^k`, `k < 16`.
    tw32: Vec<Complex<R>>,
}

impl<R: FftScalar> SmallKernel<R> {
    /// Build the kernel for `n ∈ {1, 2, 4, 8, 16, 32}`.
    pub(crate) fn new(n: usize) -> Self {
        debug_assert!(matches!(n, 1 | 2 | 4 | 8 | 16 | 32));
        let w8 = twiddle::<R>(1, 8);
        let tw16 = if n >= 16 {
            (0..8).map(|k| twiddle::<R>(k, 16)).collect()
        } else {
            Vec::new()
        };
        let tw32 = if n == 32 {
            (0..16).map(|k| twiddle::<R>(k, 32)).collect()
        } else {
            Vec::new()
        };
        Self { n, w8, tw16, tw32 }
    }

    /// Forward transform in place; `data.len()` must equal the kernel length.
    pub(crate) fn execute(&self, data: &mut [Complex<R>]) {
        debug_assert_eq!(data.len(), self.n);
        match self.n {
            1 => {}
            2 => fft2(data),
            4 => fft4(data),
            8 => self.fft8(data),
            16 => self.fft16(data),
            32 => self.fft32(data),
            _ => unreachable!("SmallKernel only handles lengths 1-32"),
        }
    }

    fn fft8(&self, d: &mut [Complex<R>]) {
        let mut e = [czero::<R>(); 4];
        let mut o = [czero::<R>(); 4];
        for j in 0..4 {
            e[j] = d[2 * j];
            o[j] = d[2 * j + 1];
        }
        fft4(&mut e);
        fft4(&mut o);
        let w = [
            Complex::new(R::one(), R::zero()),
            self.w8,
            mul_neg_i(Complex::new(R::one(), R::zero())),
            mul_neg_i(self.w8),
        ];
        for k in 0..4 {
            let t = w[k] * o[k];
            d[k] = e[k] + t;
            d[k + 4] = e[k] - t;
        }
    }

    fn fft16(&self, d: &mut [Complex<R>]) {
        let mut e = [czero::<R>(); 8];
        let mut o = [czero::<R>(); 8];
        for j in 0..8 {
            e[j] = d[2 * j];
            o[j] = d[2 * j + 1];
        }
        self.fft8(&mut e);
        self.fft8(&mut o);
        for k in 0..8 {
            let t = self.tw16[k] * o[k];
            d[k] = e[k] + t;
            d[k + 8] = e[k] - t;
        }
    }

    fn fft32(&self, d: &mut [Complex<R>]) {
        let mut e = [czero::<R>(); 16];
        let mut o = [czero::<R>(); 16];
        for j in 0..16 {
            e[j] = d[2 * j];
            o[j] = d[2 * j + 1];
        }
        self.fft16(&mut e);
        self.fft16(&mut o);
        for k in 0..16 {
            let t = self.tw32[k] * o[k];
            d[k] = e[k] + t;
            d[k + 16] = e[k] - t;
        }
    }
}

/// Length-2 butterfly.
fn fft2<R: FftScalar>(d: &mut [Complex<R>]) {
    let a = d[0];
    let b = d[1];
    d[0] = a + b;
    d[1] = a - b;
}

/// Length-4 straight-line radix-4 butterfly (forward, `W_4 = −i`).
fn fft4<R: FftScalar>(d: &mut [Complex<R>]) {
    let t0 = d[0] + d[2];
    let t1 = d[0] - d[2];
    let t2 = d[1] + d[3];
    let t3 = d[1] - d[3];
    d[0] = t0 + t2;
    d[1] = t1 + mul_neg_i(t3);
    d[2] = t0 - t2;
    d[3] = t1 + mul_i(t3);
}
