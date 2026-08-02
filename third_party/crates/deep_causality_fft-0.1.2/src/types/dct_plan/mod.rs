/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Plan-based discrete cosine transforms (types I, II, III) on the
//! existing real-FFT core.
//!
//! * **DCT-II** rides the Makhoul length-`n` embedding: permute
//!   `v = (x₀, x₂, …, x₅, x₃, x₁)`, take the rFFT, and read
//!   `X_k = Re(e^{−iπk/(2n)} · V_k)`. The inverse build
//!   `V_k = e^{+iπk/(2n)}(X_k − i·X_{n−k})` is algebraically exact, so
//!   `execute_inverse` recovers the input to rounding with no hidden
//!   scale.
//! * **DCT-III** is the transpose pair: its unnormalized forward equals
//!   `(n/2) ×` the DCT-II inverse, and vice versa.
//! * **DCT-I** rides the even extension `y = (x₀, …, x_{n−1}, x_{n−2},
//!   …, x₁)` of length `2(n−1)`, whose rFFT half-spectrum has exactly
//!   `n` real bins: `X_k = Y_k/2`. DCT-I is its own inverse up to
//!   `2/(n−1)`.
//!
//! Conventions (unnormalized, endpoints halved for type I):
//!
//! ```text
//! DCT-I  : X_k = ½(x₀ + (−1)^k x_{n−1}) + Σ_{j=1}^{n−2} x_j cos(πjk/(n−1))
//! DCT-II : X_k = Σ_j x_j cos(π(2j+1)k/(2n))
//! DCT-III: X_k = ½x₀ + Σ_{j≥1} x_j cos(πj(2k+1)/(2n))
//! ```
//!
//! Pairings: `DCT-III(DCT-II(x)) = (n/2)·x`;
//! `DCT-I(DCT-I(x)) = ((n−1)/2)·x`. `execute_inverse` applies the exact
//! inverse (scale folded in), so `execute_inverse(execute(x)) = x` to
//! rounding for every type.
//!
//! Plans follow the crate contracts: immutable after construction,
//! caller scratch (real and complex), allocation-free execution, every
//! length O(N log N) through the planner's Bluestein fallback. The
//! naïve references live in [`crate::utils::dct`].

use deep_causality_num_complex::Complex;

use crate::errors::fft_error::FftError;
use crate::traits::fft_scalar::FftScalar;
use crate::types::rfft_plan::RfftPlan;
use crate::utils::complex_ops::conj;
use crate::utils::twiddles::twiddle;

/// The transform type a [`DctPlan`] was built for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DctType {
    /// Even-symmetric about both endpoints; requires `n ≥ 2`.
    I,
    /// Even-symmetric about the half-sample left boundary.
    II,
    /// The transpose of type II.
    III,
}

/// An immutable, reusable 1-D DCT plan.
#[derive(Debug, Clone)]
pub struct DctPlan<R: FftScalar> {
    n: usize,
    ty: DctType,
    /// Length-`n` (II/III) or length-`2(n−1)` (I) real-FFT plan.
    rplan: RfftPlan<R>,
    /// `e^{−iπk/(2n)}` for `k = 0..n` (II/III only; empty for I).
    tw: Vec<Complex<R>>,
}

impl<R: FftScalar> DctPlan<R> {
    /// Plan a DCT of the given type and length.
    ///
    /// # Errors
    /// `FftError::InvalidLength` when `n == 0`, or `n < 2` for type I.
    pub fn new(n: usize, ty: DctType) -> Result<Self, FftError> {
        if n == 0 || (ty == DctType::I && n < 2) {
            return Err(FftError::InvalidLength(n));
        }
        let (rplan, tw) = match ty {
            DctType::I => (RfftPlan::new(2 * (n - 1))?, Vec::new()),
            DctType::II | DctType::III => {
                // W^k = e^{−iπk/(2n)} = the 4n-th root twiddle at k.
                let tw = (0..=n).map(|k| twiddle::<R>(k, 4 * n)).collect();
                (RfftPlan::new(n)?, tw)
            }
        };
        Ok(Self { n, ty, rplan, tw })
    }

    /// The transform length.
    pub fn len(&self) -> usize {
        self.n
    }

    /// Always false: zero-length plans cannot be constructed.
    pub fn is_empty(&self) -> bool {
        false
    }

    /// The type this plan was built for.
    pub fn dct_type(&self) -> DctType {
        self.ty
    }

    /// Required real scratch length for both directions.
    pub fn scratch_real_len(&self) -> usize {
        match self.ty {
            DctType::I => 2 * (self.n - 1),
            DctType::II | DctType::III => self.n,
        }
    }

    /// Required complex scratch length for both directions.
    pub fn scratch_complex_len(&self) -> usize {
        self.rplan.spectrum_len() + self.rplan.scratch_len()
    }

    /// Forward transform (unnormalized, conventions in the module doc).
    ///
    /// # Errors
    /// `FftError::LengthMismatch` / `FftError::ScratchTooSmall` on buffer
    /// size violations.
    pub fn execute(
        &self,
        input: &[R],
        output: &mut [R],
        real_scratch: &mut [R],
        complex_scratch: &mut [Complex<R>],
    ) -> Result<(), FftError> {
        self.validate(input.len(), output.len(), real_scratch, complex_scratch)?;
        match self.ty {
            DctType::I => self.dct_i(input, output, real_scratch, complex_scratch),
            DctType::II => self.dct_ii(input, output, real_scratch, complex_scratch),
            DctType::III => {
                // Unnormalized DCT-III = (n/2) × exact DCT-II inverse.
                self.dct_ii_inverse(input, output, real_scratch, complex_scratch);
                let half_n =
                    R::from_usize(self.n).expect("length is representable") / (R::one() + R::one());
                for v in output.iter_mut() {
                    *v *= half_n;
                }
            }
        }
        Ok(())
    }

    /// Exact inverse of [`Self::execute`] (scale folded in):
    /// `execute_inverse(execute(x)) = x` to rounding.
    ///
    /// # Errors
    /// As [`Self::execute`].
    pub fn execute_inverse(
        &self,
        input: &[R],
        output: &mut [R],
        real_scratch: &mut [R],
        complex_scratch: &mut [Complex<R>],
    ) -> Result<(), FftError> {
        self.validate(input.len(), output.len(), real_scratch, complex_scratch)?;
        let two = R::one() + R::one();
        match self.ty {
            DctType::I => {
                // Self-inverse up to 2/(n−1).
                self.dct_i(input, output, real_scratch, complex_scratch);
                let s = two / R::from_usize(self.n - 1).expect("length is representable");
                for v in output.iter_mut() {
                    *v *= s;
                }
            }
            DctType::II => self.dct_ii_inverse(input, output, real_scratch, complex_scratch),
            DctType::III => {
                // Inverse of DCT-III = (2/n) × DCT-II.
                self.dct_ii(input, output, real_scratch, complex_scratch);
                let s = two / R::from_usize(self.n).expect("length is representable");
                for v in output.iter_mut() {
                    *v *= s;
                }
            }
        }
        Ok(())
    }

    /// DCT-I via the even extension of length `2(n−1)`.
    fn dct_i(
        &self,
        input: &[R],
        output: &mut [R],
        real_scratch: &mut [R],
        complex_scratch: &mut [Complex<R>],
    ) {
        let n = self.n;
        let m = 2 * (n - 1);
        let embed = &mut real_scratch[..m];
        embed[..n].copy_from_slice(input);
        for j in 1..n - 1 {
            embed[m - j] = input[j];
        }
        let (spec, work) = complex_scratch.split_at_mut(self.rplan.spectrum_len());
        self.rplan
            .execute(embed, spec, work)
            .expect("buffer lengths validated at the public surface");
        let two = R::one() + R::one();
        for (k, o) in output.iter_mut().enumerate() {
            *o = spec[k].re / two;
        }
    }

    /// DCT-II via the Makhoul permutation: `X_k = Re(W^k V_k)`.
    fn dct_ii(
        &self,
        input: &[R],
        output: &mut [R],
        real_scratch: &mut [R],
        complex_scratch: &mut [Complex<R>],
    ) {
        let n = self.n;
        let v = &mut real_scratch[..n];
        let half = n.div_ceil(2);
        for j in 0..half {
            v[j] = input[2 * j];
        }
        for j in 0..n / 2 {
            v[n - 1 - j] = input[2 * j + 1];
        }
        let (spec, work) = complex_scratch.split_at_mut(self.rplan.spectrum_len());
        self.rplan
            .execute(v, spec, work)
            .expect("buffer lengths validated at the public surface");

        let h = n / 2;
        for (k, o) in output.iter_mut().enumerate() {
            // V_k for k > n/2 by Hermitian symmetry of the real rFFT.
            let vk = if k <= h { spec[k] } else { conj(spec[n - k]) };
            *o = (self.tw[k] * vk).re;
        }
    }

    /// Exact DCT-II inverse: `V_k = conj(W^k)·(X_k − i·X_{n−k})`,
    /// inverse rFFT, un-permute.
    fn dct_ii_inverse(
        &self,
        input: &[R],
        output: &mut [R],
        real_scratch: &mut [R],
        complex_scratch: &mut [Complex<R>],
    ) {
        let n = self.n;
        let h = n / 2;
        let (spec, work) = complex_scratch.split_at_mut(self.rplan.spectrum_len());
        for (k, s) in spec.iter_mut().enumerate() {
            // X_n := 0 closes the k = 0 case; k = n/2 (even n) lands real.
            let x_k = input[k];
            let x_nk = if k == 0 { R::zero() } else { input[n - k] };
            let z = Complex::new(x_k, R::zero() - x_nk);
            *s = conj(self.tw[k]) * z;
        }
        debug_assert_eq!(spec.len(), h + 1);
        let v = &mut real_scratch[..n];
        self.rplan
            .execute_inverse(spec, v, work)
            .expect("buffer lengths validated at the public surface");
        let half = n.div_ceil(2);
        for j in 0..half {
            output[2 * j] = v[j];
        }
        for j in 0..n / 2 {
            output[2 * j + 1] = v[n - 1 - j];
        }
    }

    fn validate(
        &self,
        in_len: usize,
        out_len: usize,
        real_scratch: &[R],
        complex_scratch: &[Complex<R>],
    ) -> Result<(), FftError> {
        if in_len != self.n {
            return Err(FftError::LengthMismatch {
                expected: self.n,
                got: in_len,
            });
        }
        if out_len != self.n {
            return Err(FftError::LengthMismatch {
                expected: self.n,
                got: out_len,
            });
        }
        if real_scratch.len() < self.scratch_real_len() {
            return Err(FftError::ScratchTooSmall {
                required: self.scratch_real_len(),
                got: real_scratch.len(),
            });
        }
        if complex_scratch.len() < self.scratch_complex_len() {
            return Err(FftError::ScratchTooSmall {
                required: self.scratch_complex_len(),
                got: complex_scratch.len(),
            });
        }
        Ok(())
    }
}
