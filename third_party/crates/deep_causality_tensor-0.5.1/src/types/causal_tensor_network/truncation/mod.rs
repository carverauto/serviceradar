/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensorError;
use deep_causality_algebra::Real;

/// Truncation policy for any SVD-based tensor-network step (TT-SVD, rounding, MPO apply).
///
/// A singular value at sorted index `i` (singular values in non-increasing order) is **kept**
/// iff all three gates pass:
/// 1. `i < max_bond` — the hard bond-dimension cap,
/// 2. `σ_i ≥ abs_tol` — the absolute floor,
/// 3. `σ_i ≥ rel_tol · σ_0` — the relative floor (skipped when `σ_0 ≤ 0`).
///
/// At least one singular value is always retained so a bond dimension never collapses to zero.
///
/// Precision is the scalar parameter `T`; the policy carries no concrete float. A `Truncation` is
/// threaded **explicitly** into every lossy operation — there is no hidden global default.
///
/// The [`RoundStrategy`] selects *how* the truncated SVD behind each lossy step is computed —
/// deterministic one-sided Jacobi (the default, high relative accuracy) or an adaptive randomized
/// range-finder (faster on low-rank data, tolerance-accurate). The gates above are identical for
/// both strategies; only the numerical kernel differs.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Truncation<T> {
    max_bond: usize,
    rel_tol: T,
    abs_tol: T,
    strategy: RoundStrategy,
}

/// How the truncated SVD behind a lossy tensor-network step (TT-SVD, rounding, MPO apply) is computed.
///
/// The deterministic kernel is the **default**; the randomized kernel is strictly opt-in. Selecting
/// the randomized strategy makes the operation tolerance-accurate but no longer bit-reproducible
/// beyond the fixed `seed` (see [`Truncation::randomized`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RoundStrategy {
    /// One-sided Jacobi truncated SVD — high relative accuracy, the default.
    #[default]
    Deterministic,
    /// Adaptive randomized range-finder truncated SVD with Gaussian sketches, `oversample` extra
    /// sketch columns past the target rank, seeded by `seed` for reproducibility.
    Randomized { oversample: usize, seed: u64 },
}

impl<T> Truncation<T>
where
    T: Real,
{
    /// Builds a policy from all three gates.
    ///
    /// # Errors
    /// Returns [`CausalTensorError::InvalidParameter`] if `max_bond == 0` or either tolerance is
    /// negative.
    pub fn new(max_bond: usize, rel_tol: T, abs_tol: T) -> Result<Self, CausalTensorError> {
        if max_bond == 0 {
            return Err(CausalTensorError::InvalidParameter(
                "Truncation max_bond must be at least 1".to_string(),
            ));
        }
        if rel_tol < T::zero() || abs_tol < T::zero() {
            return Err(CausalTensorError::InvalidParameter(
                "Truncation tolerances must be non-negative".to_string(),
            ));
        }
        Ok(Self {
            max_bond,
            rel_tol,
            abs_tol,
            strategy: RoundStrategy::Deterministic,
        })
    }

    /// Builds a pure bond-cap policy (both tolerances zero): keep the leading `max_bond` values.
    ///
    /// # Errors
    /// Returns [`CausalTensorError::InvalidParameter`] if `max_bond == 0`.
    pub fn by_bond(max_bond: usize) -> Result<Self, CausalTensorError> {
        Self::new(max_bond, T::zero(), T::zero())
    }

    /// Builds a pure relative-tolerance policy (no bond cap): keep while `σ_i ≥ rel_tol · σ_0`.
    ///
    /// # Errors
    /// Returns [`CausalTensorError::InvalidParameter`] if `rel_tol` is negative.
    pub fn by_tol(rel_tol: T) -> Result<Self, CausalTensorError> {
        Self::new(usize::MAX, rel_tol, T::zero())
    }

    /// Returns the same policy with the **adaptive randomized** SVD strategy selected.
    ///
    /// `oversample` is the number of extra Gaussian sketch columns drawn past the target rank
    /// (a small value such as 8–10 is typical; larger trades cost for a tighter range estimate).
    /// `seed` makes the randomized run reproducible. The gate thresholds (`max_bond`/`rel_tol`/
    /// `abs_tol`) are unchanged; only the kernel that realizes them differs.
    pub fn randomized(self, oversample: usize, seed: u64) -> Self {
        Self {
            strategy: RoundStrategy::Randomized { oversample, seed },
            ..self
        }
    }

    /// The rounding/SVD strategy this policy selects.
    pub fn strategy(&self) -> RoundStrategy {
        self.strategy
    }

    /// The hard bond-dimension cap.
    pub fn max_bond(&self) -> usize {
        self.max_bond
    }

    /// The relative tolerance gate.
    pub fn rel_tol(&self) -> T {
        self.rel_tol
    }

    /// The absolute tolerance gate.
    pub fn abs_tol(&self) -> T {
        self.abs_tol
    }

    /// Returns how many leading singular values to retain under this policy.
    ///
    /// `sorted_desc` MUST be the singular values in non-increasing order. The result is at least 1
    /// (a bond never collapses to zero) and at most `sorted_desc.len()`.
    pub fn retained_rank(&self, sorted_desc: &[T]) -> usize {
        if sorted_desc.is_empty() {
            return 0;
        }
        let s0 = sorted_desc[0];
        let mut kept = 0usize;
        for (i, &s) in sorted_desc.iter().enumerate() {
            if i >= self.max_bond {
                break;
            }
            if s < self.abs_tol {
                break;
            }
            if s0 > T::zero() && s < self.rel_tol * s0 {
                break;
            }
            kept += 1;
        }
        // Keep at least one value so the bond dimension stays positive.
        kept.clamp(1, sorted_desc.len())
    }
}
