/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Real-to-complex forward (rFFT) and complex-to-real inverse (irFFT)
//! transforms with the half-spectrum layout.
//!
//! Real input of length `n` has a Hermitian-symmetric spectrum; only the
//! `n/2 + 1` non-redundant bins are produced. For even `n` the transform
//! runs through the standard packing trick — one complex FFT of length
//! `n/2` over `z_j = x_{2j} + i·x_{2j+1}` plus an O(n) unpack — so it
//! reuses the complex core at half the work and memory. Odd lengths fall
//! back to a full-length complex transform internally (no current
//! workload uses them; the path exists so the API is total).
//!
//! Normalization matches the complex plans: forward unnormalized,
//! inverse scaled by `1/n`.

use deep_causality_num_complex::Complex;

use crate::errors::fft_error::FftError;
use crate::traits::fft_scalar::FftScalar;
use crate::types::fft_plan::FftPlan;
use crate::utils::complex_ops::{conj, scale};
use crate::utils::twiddles::twiddle;

#[derive(Debug, Clone)]
enum RfftVariant<R: FftScalar> {
    /// Even length: packed half-length complex FFT plus unpack.
    Even {
        inner: FftPlan<R>,
        /// `W_n^k` for `k = 0..=n/2`.
        tw: Vec<Complex<R>>,
    },
    /// Odd length: full-length complex FFT on the realified input.
    Odd { inner: FftPlan<R> },
}

/// An immutable, reusable 1-D real FFT plan.
#[derive(Debug, Clone)]
pub struct RfftPlan<R: FftScalar> {
    n: usize,
    variant: RfftVariant<R>,
}

impl<R: FftScalar> RfftPlan<R> {
    /// Plan a real transform of length `n`.
    ///
    /// # Errors
    /// `FftError::InvalidLength` when `n == 0`.
    pub fn new(n: usize) -> Result<Self, FftError> {
        if n == 0 {
            return Err(FftError::InvalidLength(0));
        }
        let variant = if n.is_multiple_of(2) {
            let h = n / 2;
            let inner = FftPlan::new(h)?;
            let tw = (0..=h).map(|k| twiddle::<R>(k, n)).collect();
            RfftVariant::Even { inner, tw }
        } else {
            RfftVariant::Odd {
                inner: FftPlan::new(n)?,
            }
        };
        Ok(Self { n, variant })
    }

    /// The real input length.
    pub fn len(&self) -> usize {
        self.n
    }

    /// Always false: zero-length plans cannot be constructed.
    pub fn is_empty(&self) -> bool {
        false
    }

    /// Number of non-redundant spectrum bins: `n/2 + 1`.
    pub fn spectrum_len(&self) -> usize {
        self.n / 2 + 1
    }

    /// Required scratch length for both directions.
    pub fn scratch_len(&self) -> usize {
        match &self.variant {
            RfftVariant::Even { inner, .. } => self.n / 2 + inner.scratch_len(),
            RfftVariant::Odd { inner } => self.n + inner.scratch_len(),
        }
    }

    /// Forward transform: real `input` (length `n`) to the half-spectrum
    /// `output` (length `n/2 + 1`), unnormalized.
    ///
    /// # Errors
    /// `FftError::LengthMismatch` / `FftError::ScratchTooSmall` on buffer
    /// size violations.
    pub fn execute(
        &self,
        input: &[R],
        output: &mut [Complex<R>],
        scratch: &mut [Complex<R>],
    ) -> Result<(), FftError> {
        self.validate(input.len(), output.len(), scratch.len())?;
        match &self.variant {
            RfftVariant::Even { inner, tw } => {
                let h = self.n / 2;
                let (z, rest) = scratch.split_at_mut(h);
                for (j, zj) in z.iter_mut().enumerate() {
                    *zj = Complex::new(input[2 * j], input[2 * j + 1]);
                }
                inner.execute_unchecked(z, rest);
                let half = R::from_f64(0.5).expect("0.5 is exactly representable");
                for k in 0..=h {
                    let zk = if k == h { z[0] } else { z[k] };
                    let zmk = if k == 0 { z[0] } else { z[h - k] };
                    // E_k + W^k·O_k with E, O recovered from the packing.
                    let e = scale(zk + conj(zmk), half);
                    let diff = zk - conj(zmk);
                    let o = scale(Complex::new(diff.im, -diff.re), half);
                    output[k] = e + tw[k] * o;
                }
            }
            RfftVariant::Odd { inner } => {
                let (buf, rest) = scratch.split_at_mut(self.n);
                for (b, x) in buf.iter_mut().zip(input.iter()) {
                    *b = Complex::new(*x, R::zero());
                }
                inner.execute_unchecked(buf, rest);
                output.copy_from_slice(&buf[..self.spectrum_len()]);
            }
        }
        Ok(())
    }

    /// Inverse transform: half-spectrum `spectrum` (length `n/2 + 1`) to
    /// real `output` (length `n`), scaled by `1/n`.
    ///
    /// # Errors
    /// `FftError::LengthMismatch` / `FftError::ScratchTooSmall` on buffer
    /// size violations.
    pub fn execute_inverse(
        &self,
        spectrum: &[Complex<R>],
        output: &mut [R],
        scratch: &mut [Complex<R>],
    ) -> Result<(), FftError> {
        self.validate(output.len(), spectrum.len(), scratch.len())?;
        match &self.variant {
            RfftVariant::Odd { inner } => {
                let (buf, rest) = scratch.split_at_mut(self.n);
                let hl = self.spectrum_len();
                buf[..hl].copy_from_slice(spectrum);
                for k in hl..self.n {
                    buf[k] = conj(spectrum[self.n - k]);
                }
                inner.execute_dir_unchecked(buf, rest, true);
                for (x, b) in output.iter_mut().zip(buf.iter()) {
                    *x = b.re;
                }
            }
            RfftVariant::Even { inner, tw } => {
                let h = self.n / 2;
                let (z, rest) = scratch.split_at_mut(h);
                let half = R::from_f64(0.5).expect("0.5 is exactly representable");
                for (k, zk) in z.iter_mut().enumerate() {
                    let xk = spectrum[k];
                    let xmk = conj(spectrum[h - k]);
                    let e = scale(xk + xmk, half);
                    // O_k = conj(W^k)·(X_k − conj X_{h−k})/2; Z_k = E_k + i·O_k.
                    let wo = scale(xk - xmk, half);
                    let o = conj(tw[k]) * wo;
                    *zk = e + Complex::new(-o.im, o.re);
                }
                inner.execute_dir_unchecked(z, rest, true);
                for j in 0..h {
                    output[2 * j] = z[j].re;
                    output[2 * j + 1] = z[j].im;
                }
            }
        }
        Ok(())
    }

    fn validate(
        &self,
        real_len: usize,
        spec_len: usize,
        scratch_len: usize,
    ) -> Result<(), FftError> {
        if real_len != self.n {
            return Err(FftError::LengthMismatch {
                expected: self.n,
                got: real_len,
            });
        }
        if spec_len != self.spectrum_len() {
            return Err(FftError::LengthMismatch {
                expected: self.spectrum_len(),
                got: spec_len,
            });
        }
        let required = self.scratch_len();
        if scratch_len < required {
            return Err(FftError::ScratchTooSmall {
                required,
                got: scratch_len,
            });
        }
        Ok(())
    }
}
