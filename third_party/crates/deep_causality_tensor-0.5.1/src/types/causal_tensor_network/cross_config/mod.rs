/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensorError;
use deep_causality_algebra::Real;

/// Controls for TT-cross construction of a tensor train from an oracle.
///
/// TT-cross convergence is heuristic; these bound the work and the accepted accuracy. The cross
/// stops when a sweep leaves the sampled residual below `tol` or when `max_sweeps` is reached, and
/// no bond dimension exceeds `rank_cap`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CrossConfig<T> {
    max_sweeps: usize,
    rank_cap: usize,
    tol: T,
    check_samples: usize,
    seed: u64,
}

impl<T> CrossConfig<T>
where
    T: Real,
{
    /// Builds a cross configuration.
    ///
    /// # Errors
    /// Returns [`CausalTensorError::InvalidParameter`] if `max_sweeps == 0`, `rank_cap == 0`, or
    /// `tol` is negative.
    pub fn new(
        max_sweeps: usize,
        rank_cap: usize,
        tol: T,
        check_samples: usize,
        seed: u64,
    ) -> Result<Self, CausalTensorError> {
        if max_sweeps == 0 || rank_cap == 0 {
            return Err(CausalTensorError::InvalidParameter(
                "CrossConfig max_sweeps and rank_cap must be at least 1".to_string(),
            ));
        }
        if tol < T::zero() {
            return Err(CausalTensorError::InvalidParameter(
                "CrossConfig tol must be non-negative".to_string(),
            ));
        }
        Ok(Self {
            max_sweeps,
            rank_cap,
            tol,
            check_samples,
            seed,
        })
    }

    /// A reasonable default: up to `max_sweeps` sweeps, the given rank cap and tolerance, 256 random
    /// residual-check samples, and a fixed seed.
    ///
    /// # Errors
    /// As [`CrossConfig::new`].
    pub fn with_rank_cap(rank_cap: usize, tol: T) -> Result<Self, CausalTensorError> {
        Self::new(8, rank_cap, tol, 256, 0x1234_5678)
    }

    /// Maximum number of alternating sweeps.
    pub fn max_sweeps(&self) -> usize {
        self.max_sweeps
    }
    /// Hard cap on every bond dimension.
    pub fn rank_cap(&self) -> usize {
        self.rank_cap
    }
    /// Accepted sampled residual.
    pub fn tol(&self) -> T {
        self.tol
    }
    /// Number of random points used to estimate the residual.
    pub fn check_samples(&self) -> usize {
        self.check_samples
    }
    /// Seed for the deterministic pivoting/sampling.
    pub fn seed(&self) -> u64 {
        self.seed
    }
}
