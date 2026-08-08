/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The N-dimensional complex FFT plan: batched strided 1-D transforms
//! along each axis (row-column decomposition), with one shared 1-D plan
//! per distinct axis length.

pub(crate) mod axis;

use deep_causality_num_complex::Complex;

use crate::errors::fft_error::FftError;
use crate::traits::fft_scalar::FftScalar;
use crate::types::fft_plan::FftPlan;
use crate::types::fft_plan_nd::axis::{last_axis, mid_axis};

/// An immutable, reusable N-dimensional complex FFT plan over a
/// row-major array of the given shape.
///
/// Normalization follows the 1-D contract per axis: forward
/// unnormalized, inverse scaled by `1/N` overall (`N` = total element
/// count), so `execute_inverse(execute(x)) = x` to rounding.
#[derive(Debug, Clone)]
pub struct FftPlanNd<R: FftScalar> {
    shape: Vec<usize>,
    n: usize,
    /// One plan per distinct axis length.
    plans: Vec<FftPlan<R>>,
    /// Axis index → index into `plans`.
    axis_plan: Vec<usize>,
    scratch: usize,
}

impl<R: FftScalar> FftPlanNd<R> {
    /// Plan a transform over `shape` (row-major).
    ///
    /// # Errors
    /// `FftError::InvalidLength` when the shape is empty or any axis is
    /// zero.
    pub fn new(shape: &[usize]) -> Result<Self, FftError> {
        if shape.is_empty() || shape.contains(&0) {
            return Err(FftError::InvalidLength(0));
        }
        let n: usize = shape.iter().product();
        let (plans, axis_plan) = build_axis_plans::<R>(shape)?;

        // Last axis transforms in place with the 1-D plan's scratch; every
        // other axis additionally needs its block (len·inner) for the
        // gather/scatter transpose.
        let mut scratch = 0usize;
        for (a, &len) in shape.iter().enumerate() {
            if len == 1 {
                continue;
            }
            let p = &plans[axis_plan[a]];
            let need = if a == shape.len() - 1 {
                p.scratch_len()
            } else {
                let inner: usize = shape[a + 1..].iter().product();
                len * inner + p.scratch_len()
            };
            scratch = scratch.max(need);
        }

        Ok(Self {
            shape: shape.to_vec(),
            n,
            plans,
            axis_plan,
            scratch,
        })
    }

    /// The shape this plan transforms.
    pub fn shape(&self) -> &[usize] {
        &self.shape
    }

    /// Total element count.
    pub fn len(&self) -> usize {
        self.n
    }

    /// Always false: empty shapes cannot be constructed.
    pub fn is_empty(&self) -> bool {
        false
    }

    /// Required scratch length for both directions.
    pub fn scratch_len(&self) -> usize {
        self.scratch
    }

    /// Forward transform in place (unnormalized).
    ///
    /// # Errors
    /// `FftError::LengthMismatch` / `FftError::ScratchTooSmall` on buffer
    /// size violations.
    pub fn execute(
        &self,
        data: &mut [Complex<R>],
        scratch: &mut [Complex<R>],
    ) -> Result<(), FftError> {
        self.validate(data.len(), scratch.len())?;
        self.execute_dir(data, scratch, false);
        Ok(())
    }

    /// Inverse transform in place, scaled by `1/N` overall.
    ///
    /// # Errors
    /// Same conditions as [`FftPlanNd::execute`].
    pub fn execute_inverse(
        &self,
        data: &mut [Complex<R>],
        scratch: &mut [Complex<R>],
    ) -> Result<(), FftError> {
        self.validate(data.len(), scratch.len())?;
        self.execute_dir(data, scratch, true);
        Ok(())
    }

    fn execute_dir(&self, data: &mut [Complex<R>], scratch: &mut [Complex<R>], inverse: bool) {
        let d = self.shape.len();
        for a in 0..d {
            let len = self.shape[a];
            if len == 1 {
                continue;
            }
            let plan = &self.plans[self.axis_plan[a]];
            if a == d - 1 {
                last_axis(data, len, plan, scratch, inverse);
            } else {
                let inner: usize = self.shape[a + 1..].iter().product();
                mid_axis(data, len, inner, plan, scratch, inverse);
            }
        }
    }

    fn validate(&self, data_len: usize, scratch_len: usize) -> Result<(), FftError> {
        if data_len != self.n {
            return Err(FftError::LengthMismatch {
                expected: self.n,
                got: data_len,
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

/// Build one 1-D plan per distinct axis length, plus the axis→plan map.
pub(crate) fn build_axis_plans<R: FftScalar>(
    shape: &[usize],
) -> Result<(Vec<FftPlan<R>>, Vec<usize>), FftError> {
    let mut plans: Vec<FftPlan<R>> = Vec::new();
    let mut axis_plan = Vec::with_capacity(shape.len());
    for &len in shape {
        let idx = match plans.iter().position(|p| p.len() == len) {
            Some(i) => i,
            None => {
                plans.push(FftPlan::new(len)?);
                plans.len() - 1
            }
        };
        axis_plan.push(idx);
    }
    Ok((plans, axis_plan))
}
