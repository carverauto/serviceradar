/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The N-dimensional real FFT plan: an rFFT along the last (contiguous)
//! axis produces the half-spectrum array of shape `[..., n_last/2 + 1]`,
//! then complex transforms run along every other axis of that array.
//! This is the transform pair the spectral Poisson solve consumes.

use deep_causality_num_complex::Complex;

use crate::errors::fft_error::FftError;
use crate::traits::fft_scalar::FftScalar;
use crate::types::fft_plan::FftPlan;
use crate::types::fft_plan_nd::axis::mid_axis;
use crate::types::fft_plan_nd::build_axis_plans;
use crate::types::rfft_plan::RfftPlan;

/// An immutable, reusable N-dimensional real-to-complex FFT plan over a
/// row-major real array of the given shape.
///
/// Normalization: forward unnormalized; inverse scaled by `1/N` overall
/// (`N` = real element count), so the pair round-trips to rounding.
#[derive(Debug, Clone)]
pub struct RfftPlanNd<R: FftScalar> {
    shape: Vec<usize>,
    spec_shape: Vec<usize>,
    n_real: usize,
    n_spec: usize,
    rplan: RfftPlan<R>,
    /// Plans for the complex axes (all but the last), over `spec_shape`.
    plans: Vec<FftPlan<R>>,
    axis_plan: Vec<usize>,
    scratch: usize,
}

impl<R: FftScalar> RfftPlanNd<R> {
    /// Plan a real transform over `shape` (row-major).
    ///
    /// # Errors
    /// `FftError::InvalidLength` when the shape is empty or any axis is
    /// zero.
    pub fn new(shape: &[usize]) -> Result<Self, FftError> {
        if shape.is_empty() || shape.contains(&0) {
            return Err(FftError::InvalidLength(0));
        }
        let d = shape.len();
        let n_last = shape[d - 1];
        let rplan = RfftPlan::new(n_last)?;

        let mut spec_shape = shape.to_vec();
        spec_shape[d - 1] = rplan.spectrum_len();
        let n_real: usize = shape.iter().product();
        let n_spec: usize = spec_shape.iter().product();

        // Complex plans for axes 0..d-1 (the last axis belongs to rplan;
        // its slot in axis_plan is never used).
        let (plans, axis_plan) = build_axis_plans::<R>(&spec_shape[..d - 1])?;

        let mut scratch = rplan.scratch_len();
        for (a, &len) in spec_shape[..d - 1].iter().enumerate() {
            if len == 1 {
                continue;
            }
            let p = &plans[axis_plan[a]];
            let inner: usize = spec_shape[a + 1..].iter().product();
            scratch = scratch.max(len * inner + p.scratch_len());
        }

        Ok(Self {
            shape: shape.to_vec(),
            spec_shape,
            n_real,
            n_spec,
            rplan,
            plans,
            axis_plan,
            scratch,
        })
    }

    /// The real-domain shape.
    pub fn shape(&self) -> &[usize] {
        &self.shape
    }

    /// The half-spectrum shape `[..., n_last/2 + 1]`.
    pub fn spectrum_shape(&self) -> &[usize] {
        &self.spec_shape
    }

    /// Real element count.
    pub fn len(&self) -> usize {
        self.n_real
    }

    /// Always false: empty shapes cannot be constructed.
    pub fn is_empty(&self) -> bool {
        false
    }

    /// Half-spectrum element count.
    pub fn spectrum_len(&self) -> usize {
        self.n_spec
    }

    /// Required scratch length for both directions.
    pub fn scratch_len(&self) -> usize {
        self.scratch
    }

    /// Forward transform: real `input` to the half-spectrum `output`
    /// (unnormalized).
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
        let d = self.shape.len();
        let n_last = self.shape[d - 1];
        let hl = self.rplan.spectrum_len();

        for (in_line, out_line) in input.chunks_exact(n_last).zip(output.chunks_exact_mut(hl)) {
            self.rplan
                .execute(in_line, out_line, scratch)
                .expect("line lengths are validated by construction");
        }
        self.complex_axes(output, scratch, false);
        Ok(())
    }

    /// Inverse transform: half-spectrum `spectrum` to real `output`,
    /// scaled by `1/N` overall. The spectrum buffer is consumed — the
    /// inverse complex passes run in place on it.
    ///
    /// # Errors
    /// `FftError::LengthMismatch` / `FftError::ScratchTooSmall` on buffer
    /// size violations.
    pub fn execute_inverse(
        &self,
        spectrum: &mut [Complex<R>],
        output: &mut [R],
        scratch: &mut [Complex<R>],
    ) -> Result<(), FftError> {
        self.validate(output.len(), spectrum.len(), scratch.len())?;
        let d = self.shape.len();
        let n_last = self.shape[d - 1];
        let hl = self.rplan.spectrum_len();

        self.complex_axes(spectrum, scratch, true);
        for (spec_line, out_line) in spectrum
            .chunks_exact(hl)
            .zip(output.chunks_exact_mut(n_last))
        {
            self.rplan
                .execute_inverse(spec_line, out_line, scratch)
                .expect("line lengths are validated by construction");
        }
        Ok(())
    }

    /// The complex transforms along every non-last axis of the spectrum
    /// array.
    fn complex_axes(&self, spec: &mut [Complex<R>], scratch: &mut [Complex<R>], inverse: bool) {
        let d = self.spec_shape.len();
        for a in 0..d.saturating_sub(1) {
            let len = self.spec_shape[a];
            if len == 1 {
                continue;
            }
            let plan = &self.plans[self.axis_plan[a]];
            let inner: usize = self.spec_shape[a + 1..].iter().product();
            mid_axis(spec, len, inner, plan, scratch, inverse);
        }
    }

    fn validate(
        &self,
        real_len: usize,
        spec_len: usize,
        scratch_len: usize,
    ) -> Result<(), FftError> {
        if real_len != self.n_real {
            return Err(FftError::LengthMismatch {
                expected: self.n_real,
                got: real_len,
            });
        }
        if spec_len != self.n_spec {
            return Err(FftError::LengthMismatch {
                expected: self.n_spec,
                got: spec_len,
            });
        }
        if scratch_len < self.scratch {
            return Err(FftError::ScratchTooSmall {
                required: self.scratch,
                got: scratch_len,
            });
        }
        Ok(())
    }
}
