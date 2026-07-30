/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The 1-D complex FFT plan and its planner.

mod bluestein;
mod small;
mod stockham;

use deep_causality_num_complex::Complex;

use crate::errors::fft_error::FftError;
use crate::traits::fft_scalar::FftScalar;
use crate::types::fft_plan::bluestein::BluesteinKernel;
use crate::types::fft_plan::small::SmallKernel;
use crate::types::fft_plan::stockham::StockhamPipeline;
use crate::utils::complex_ops::{conj_in_place, scale};

/// Planner-selected kernel. The naïve DFT is deliberately absent — it is
/// a test-only reference (`crate::utils::dft`).
#[derive(Debug, Clone)]
enum FftKernel<R: FftScalar> {
    /// Hardcoded small power-of-two kernel (lengths 1–32), scratch-free.
    Small(SmallKernel<R>),
    /// Mixed radix-4/radix-2 Stockham pipeline (powers of two above 32).
    Stockham(StockhamPipeline<R>),
    /// Chirp-z fallback for every other length.
    Bluestein(BluesteinKernel<R>),
}

/// An immutable, reusable 1-D complex FFT plan.
///
/// Build once per transform length with [`FftPlan::new`], then call
/// [`FftPlan::execute`] / [`FftPlan::execute_inverse`] any number of times
/// with a caller-provided scratch buffer of at least
/// [`FftPlan::scratch_len`] elements. Execution allocates nothing.
///
/// Normalization: forward unnormalized, inverse scaled by `1/n`. The
/// inverse is conjugation reuse of the forward kernel.
#[derive(Debug, Clone)]
pub struct FftPlan<R: FftScalar> {
    n: usize,
    kernel: FftKernel<R>,
}

impl<R: FftScalar> FftPlan<R> {
    /// Plan a transform of length `n`.
    ///
    /// # Errors
    /// `FftError::InvalidLength` when `n == 0`.
    pub fn new(n: usize) -> Result<Self, FftError> {
        if n == 0 {
            return Err(FftError::InvalidLength(0));
        }
        let kernel = if n <= 32 && n.is_power_of_two() {
            FftKernel::Small(SmallKernel::new(n))
        } else if n.is_power_of_two() {
            FftKernel::Stockham(StockhamPipeline::new(n))
        } else {
            FftKernel::Bluestein(BluesteinKernel::new(n))
        };
        Ok(Self { n, kernel })
    }

    /// Internal constructor for the power-of-two inner plans Bluestein
    /// builds; `n` is a power of two by construction.
    pub(crate) fn new_power_of_two(n: usize) -> Self {
        debug_assert!(n.is_power_of_two());
        let kernel = if n <= 32 {
            FftKernel::Small(SmallKernel::new(n))
        } else {
            FftKernel::Stockham(StockhamPipeline::new(n))
        };
        Self { n, kernel }
    }

    /// The transform length.
    pub fn len(&self) -> usize {
        self.n
    }

    /// Always false: zero-length plans cannot be constructed.
    pub fn is_empty(&self) -> bool {
        false
    }

    /// Required scratch length for [`FftPlan::execute`] and
    /// [`FftPlan::execute_inverse`].
    pub fn scratch_len(&self) -> usize {
        match &self.kernel {
            FftKernel::Small(_) => 0,
            FftKernel::Stockham(_) => self.n,
            FftKernel::Bluestein(b) => b.scratch_len(),
        }
    }

    /// Forward transform of `data` in place (unnormalized).
    ///
    /// # Errors
    /// * `FftError::LengthMismatch` when `data.len() != self.len()`.
    /// * `FftError::ScratchTooSmall` when the scratch buffer is shorter
    ///   than [`FftPlan::scratch_len`].
    pub fn execute(
        &self,
        data: &mut [Complex<R>],
        scratch: &mut [Complex<R>],
    ) -> Result<(), FftError> {
        self.validate(data, scratch)?;
        self.execute_unchecked(data, scratch);
        Ok(())
    }

    /// Inverse transform of `data` in place, scaled by `1/n`:
    /// `ifft(x) = conj(fft(conj(x))) / n`.
    ///
    /// # Errors
    /// Same conditions as [`FftPlan::execute`].
    pub fn execute_inverse(
        &self,
        data: &mut [Complex<R>],
        scratch: &mut [Complex<R>],
    ) -> Result<(), FftError> {
        self.validate(data, scratch)?;
        self.execute_inverse_unchecked(data, scratch);
        Ok(())
    }

    /// Forward or inverse by flag — the shared entry point the
    /// N-dimensional plans dispatch through.
    pub(crate) fn execute_dir_unchecked(
        &self,
        data: &mut [Complex<R>],
        scratch: &mut [Complex<R>],
        inverse: bool,
    ) {
        if inverse {
            self.execute_inverse_unchecked(data, scratch);
        } else {
            self.execute_unchecked(data, scratch);
        }
    }

    /// Forward transform without buffer validation (lengths guaranteed by
    /// the caller).
    pub(crate) fn execute_unchecked(&self, data: &mut [Complex<R>], scratch: &mut [Complex<R>]) {
        match &self.kernel {
            FftKernel::Small(k) => k.execute(data),
            FftKernel::Stockham(k) => k.execute(data, scratch),
            FftKernel::Bluestein(k) => k.execute(data, scratch),
        }
    }

    fn execute_inverse_unchecked(&self, data: &mut [Complex<R>], scratch: &mut [Complex<R>]) {
        conj_in_place(data);
        self.execute_unchecked(data, scratch);
        let inv_n = R::one() / R::from_usize(self.n).expect("length is representable");
        for z in data.iter_mut() {
            // Fused conjugate-and-scale of the conjugation-reuse identity.
            *z = scale(Complex::new(z.re, -z.im), inv_n);
        }
    }

    fn validate(&self, data: &[Complex<R>], scratch: &[Complex<R>]) -> Result<(), FftError> {
        if data.len() != self.n {
            return Err(FftError::LengthMismatch {
                expected: self.n,
                got: data.len(),
            });
        }
        let required = self.scratch_len();
        if scratch.len() < required {
            return Err(FftError::ScratchTooSmall {
                required,
                got: scratch.len(),
            });
        }
        Ok(())
    }
}
