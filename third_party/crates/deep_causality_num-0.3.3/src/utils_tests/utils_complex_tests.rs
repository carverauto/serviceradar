/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Complex;

// Helper for approximate equality for floats
pub fn assert_approx_eq(a: f64, b: f64, epsilon: f64) {
    assert!(
        (a - b).abs() < epsilon,
        "{} is not approximately equal to {}",
        a,
        b
    );
}

// Helper for approximate equality for complex numbers
pub fn assert_complex_approx_eq(a: Complex<f64>, b: Complex<f64>, epsilon: f64) {
    assert_approx_eq(a.re, b.re, epsilon);
    assert_approx_eq(a.im, b.im, epsilon);
}
