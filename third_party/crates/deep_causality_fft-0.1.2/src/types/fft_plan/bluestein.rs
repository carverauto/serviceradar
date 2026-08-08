/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Bluestein's chirp-z fallback for arbitrary lengths.
//!
//! `jk = (j² + k² − (k−j)²)/2` turns the DFT into a circular convolution
//! against the chirp `c_t = e^{-iπt²/n}`, evaluated with the power-of-two
//! core at length `m = 2^⌈log₂(2n−1)⌉`. This keeps every length
//! O(N log N) — the planner never falls off a quadratic cliff. The chirp
//! angle is reduced as `π·t²/n = 2π·(t² mod 2n)/(2n)` in integer
//! arithmetic before any trigonometry.

use deep_causality_num_complex::Complex;

use crate::traits::fft_scalar::FftScalar;
use crate::types::fft_plan::FftPlan;
use crate::utils::complex_ops::{conj, conj_in_place, czero, scale};
use crate::utils::twiddles::twiddle;

/// Precomputed Bluestein state for one arbitrary length.
#[derive(Debug, Clone)]
pub(crate) struct BluesteinKernel<R: FftScalar> {
    n: usize,
    m: usize,
    /// `c_k = e^{-iπk²/n}` for `k < n`.
    chirp: Vec<Complex<R>>,
    /// Forward FFT (length `m`) of the padded, wrapped conjugate chirp.
    b_spec: Vec<Complex<R>>,
    /// Power-of-two inner plan of length `m` (boxed: the type is recursive).
    inner: Box<FftPlan<R>>,
}

impl<R: FftScalar> BluesteinKernel<R> {
    pub(crate) fn new(n: usize) -> Self {
        debug_assert!(n > 1 && !n.is_power_of_two());
        let m = (2 * n - 1).next_power_of_two();
        let inner = Box::new(FftPlan::new_power_of_two(m));

        let chirp: Vec<Complex<R>> = (0..n)
            .map(|k| twiddle::<R>((k * k) % (2 * n), 2 * n))
            .collect();

        // b_t = conj(c_t) for |t| < n, wrapped onto [0, m).
        let mut b_spec = vec![czero::<R>(); m];
        b_spec[0] = conj(chirp[0]);
        for k in 1..n {
            let v = conj(chirp[k]);
            b_spec[k] = v;
            b_spec[m - k] = v;
        }
        // One-time construction cost: transform b in place to its spectrum.
        let mut build_scratch = vec![czero::<R>(); inner.scratch_len()];
        inner.execute_unchecked(&mut b_spec, &mut build_scratch);

        Self {
            n,
            m,
            chirp,
            b_spec,
            inner,
        }
    }

    /// Scratch: the length-`m` convolution buffer plus the inner plan's own
    /// scratch.
    pub(crate) fn scratch_len(&self) -> usize {
        self.m + self.inner.scratch_len()
    }

    /// Forward transform of `data` (length `n`) via chirp convolution.
    pub(crate) fn execute(&self, data: &mut [Complex<R>], scratch: &mut [Complex<R>]) {
        let (buf, rest) = scratch.split_at_mut(self.m);

        // a_k = x_k · c_k, zero-padded to m.
        for k in 0..self.n {
            buf[k] = data[k] * self.chirp[k];
        }
        for slot in buf.iter_mut().take(self.m).skip(self.n) {
            *slot = czero::<R>();
        }

        // Pointwise convolution in the frequency domain.
        self.inner.execute_unchecked(buf, rest);
        for (a, b) in buf.iter_mut().zip(self.b_spec.iter()) {
            *a *= *b;
        }

        // Inverse inner transform by conjugation reuse, fused with the
        // final chirp multiply: X_k = c_k · (a ⊛ b)_k.
        conj_in_place(buf);
        self.inner.execute_unchecked(buf, rest);
        let inv_m = R::one() / R::from_usize(self.m).expect("length is representable");
        for k in 0..self.n {
            data[k] = scale(conj(buf[k]), inv_m) * self.chirp[k];
        }
    }
}
