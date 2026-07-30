/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use deep_causality_algebra::RealField;
use std::iter::Sum;

// This trait abstracts the differences between Real (f64) and Complex (Complex<f64>)
// specifically for norm calculations.
pub trait ScalarEval {
    /// The underlying real type (e.g., f64 for both f64 and `Complex<f64>`)
    type Real: RealField + Copy + Sum;

    /// Returns the squared magnitude (absolute value squared).
    /// For Real x: x*x
    /// For Complex z: |z|^2 = real^2 + imag^2
    fn modulus_squared(&self) -> Self::Real;

    /// Scales the value by a real number.
    fn scale_by_real(&self, s: Self::Real) -> Self;
}
