/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Octonion;

// Helper for approximate equality for floats
pub fn assert_approx_eq(a: f64, b: f64, epsilon: f64) {
    assert!(
        (a - b).abs() < epsilon,
        "{} is not approximately equal to {}",
        a,
        b
    );
}

// Helper for approximate equality for octonion numbers
pub fn assert_octonion_approx_eq(a: Octonion<f64>, b: Octonion<f64>, epsilon: f64) {
    assert_approx_eq(a.s, b.s, epsilon);
    assert_approx_eq(a.e1, b.e1, epsilon);
    assert_approx_eq(a.e2, b.e2, epsilon);
    assert_approx_eq(a.e3, b.e3, epsilon);
    assert_approx_eq(a.e4, b.e4, epsilon);
    assert_approx_eq(a.e5, b.e5, epsilon);
    assert_approx_eq(a.e6, b.e6, epsilon);
    assert_approx_eq(a.e7, b.e7, epsilon);
}
