/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensorError;
use deep_causality_algebra::Real;

/// Controls for the alternating-sweep (ALS) tensor-train solvers.
///
/// A solver stops when a full sweep leaves the residual below `tol` or when `max_sweeps` is reached
/// (the latter returns [`CausalTensorError::SweepDidNotConverge`]). `ridge` is a small Tikhonov
/// regularization added to each local normal-equation system so the solve stays finite when the
/// local design is rank-deficient.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SolveConfig<T> {
    max_sweeps: usize,
    tol: T,
    ridge: T,
}

impl<T> SolveConfig<T>
where
    T: Real,
{
    /// Builds a solve configuration.
    ///
    /// # Errors
    /// Returns [`CausalTensorError::InvalidParameter`] if `max_sweeps == 0`, or `tol` / `ridge` is
    /// negative.
    pub fn new(max_sweeps: usize, tol: T, ridge: T) -> Result<Self, CausalTensorError> {
        if max_sweeps == 0 {
            return Err(CausalTensorError::InvalidParameter(
                "SolveConfig max_sweeps must be at least 1".to_string(),
            ));
        }
        if tol < T::zero() || ridge < T::zero() {
            return Err(CausalTensorError::InvalidParameter(
                "SolveConfig tol and ridge must be non-negative".to_string(),
            ));
        }
        Ok(Self {
            max_sweeps,
            tol,
            ridge,
        })
    }

    /// Maximum number of forward+backward sweeps.
    pub fn max_sweeps(&self) -> usize {
        self.max_sweeps
    }
    /// Residual tolerance for early stopping.
    pub fn tol(&self) -> T {
        self.tol
    }
    /// Tikhonov ridge added to each local system.
    pub fn ridge(&self) -> T {
        self.ridge
    }
}
