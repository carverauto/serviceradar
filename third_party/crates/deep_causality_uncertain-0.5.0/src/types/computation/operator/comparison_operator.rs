/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_algebra::Real;

/// Defines binary comparison operations on a real scalar, returning a bool.
#[derive(Debug, Clone, Copy, PartialOrd, PartialEq)]
pub enum ComparisonOperator {
    GreaterThan,
    LessThan,
    EqualTo,
}

impl ComparisonOperator {
    /// Apply the comparison at the operands' precision. Generic over `R: Real`, so it
    /// serves `f64` (bit-identically — `R::epsilon()` is `f64::EPSILON`) and `Float106`.
    /// `apply` here is against a threshold, a common case.
    pub fn apply<R: Real>(&self, a: R, b: R) -> bool {
        match self {
            ComparisonOperator::GreaterThan => a > b,
            ComparisonOperator::LessThan => a < b,
            // Use a small epsilon for robust floating-point equality checks.
            ComparisonOperator::EqualTo => {
                if a.is_nan() || b.is_nan() {
                    false // NaN is never equal to anything, including itself
                } else if a.is_infinite() || b.is_infinite() {
                    a == b // Handles Inf == Inf, Inf == -Inf, Inf == finite
                } else {
                    // Small-epsilon equality for finite numbers, at R's precision.
                    (a - b).abs() < R::epsilon()
                }
            }
        }
    }
}
use std::fmt;

impl fmt::Display for ComparisonOperator {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            ComparisonOperator::GreaterThan => write!(f, ">"),
            ComparisonOperator::LessThan => write!(f, "<"),
            ComparisonOperator::EqualTo => write!(f, "=="),
        }
    }
}
