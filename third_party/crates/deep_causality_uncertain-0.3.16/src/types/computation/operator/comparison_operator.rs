/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Defines binary comparison operations that take an f64 and return a bool.
#[derive(Debug, Clone, Copy, PartialOrd, PartialEq)]
pub enum ComparisonOperator {
    GreaterThan,
    LessThan,
    EqualTo,
}

impl ComparisonOperator {
    // Note: `apply` here is against a constant threshold, a common case.
    pub fn apply(&self, a: f64, b: f64) -> bool {
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
                    // Use a small epsilon for robust floating-point equality checks for finite numbers.
                    (a - b).abs() < f64::EPSILON
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
