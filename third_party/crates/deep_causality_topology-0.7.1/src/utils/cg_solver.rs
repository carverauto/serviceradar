/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Gauge-fixing helper for the matrix-free Hodge solve.
//!
//! The conjugate-gradient solver itself now lives in
//! [`deep_causality_sparse::cg_solve`]; this module retains only the
//! crate-private gauge helper that the Hodge decomposition applies around that
//! solve. The constant functions are always in the kernel of `Δ_0`, so the
//! grade-0 Poisson solve is degenerate by exactly one dimension; subtracting the
//! mean fixes the gauge and makes the result unique.

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;

/// Subtract the mean of `v` from every entry, in place.
///
/// Used to fix the gauge of a 0-form potential before computing its
/// exterior derivative — the constant functions are always in the kernel of
/// `Δ_0`, so the solve is degenerate by exactly one dimension and the result
/// is only unique up to an additive constant.
pub(crate) fn subtract_mean_in_place<R>(v: &mut [R])
where
    R: RealField + FromPrimitive,
{
    if v.is_empty() {
        return;
    }
    let n = <R as FromPrimitive>::from_usize(v.len())
        .expect("v.len() is representable in every supported RealField");
    let sum: R = v.iter().copied().fold(R::zero(), |a, b| a + b);
    let mean = sum / n;
    for entry in v.iter_mut() {
        *entry -= mean;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subtract_mean_in_place_zeros_a_constant_vector() {
        let mut v = vec![5.0_f64; 7];
        subtract_mean_in_place(&mut v);
        for &x in &v {
            assert!(x.abs() < 1e-15);
        }
    }

    #[test]
    fn subtract_mean_in_place_preserves_zero_mean_input() {
        let mut v = vec![-2.0_f64, -1.0, 0.0, 1.0, 2.0];
        let original = v.clone();
        subtract_mean_in_place(&mut v);
        for (a, b) in v.iter().zip(original.iter()) {
            assert!((a - b).abs() < 1e-15);
        }
    }

    #[test]
    fn subtract_mean_in_place_handles_empty_slice() {
        let mut v: Vec<f64> = vec![];
        subtract_mean_in_place(&mut v);
        assert!(v.is_empty());
    }

    #[test]
    fn subtract_mean_in_place_subtracts_correct_mean_from_arbitrary_input() {
        let mut v = vec![1.0_f64, 2.0, 3.0, 4.0]; // mean = 2.5
        subtract_mean_in_place(&mut v);
        let expected = [-1.5, -0.5, 0.5, 1.5];
        for (a, e) in v.iter().zip(expected.iter()) {
            assert!((a - e).abs() < 1e-15);
        }
    }
}
