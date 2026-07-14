/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_algebra::RealField;

/// Defines binary arithmetic operations on any real scalar.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ArithmeticOperator {
    Add,
    Sub,
    Mul,
    Div,
    /// The lesser operand — the `[0, 1]` lattice meet of the MV `Verdict` carrier.
    Min,
    /// The greater operand — the `[0, 1]` lattice join of the MV `Verdict` carrier.
    Max,
}

impl ArithmeticOperator {
    /// Apply the operation at the operands' precision. Generic over `R: RealField`
    /// (`Add`/`Sub`/`Mul` from the ring, `Div` from the field, `Min`/`Max` from the order),
    /// so the same code path serves `f64` (bit-identically) and `Float106`.
    ///
    /// `Min`/`Max` select by the operands' `<=`/`>=` order and are right-biased on an incomparable
    /// pair (e.g. a `NaN` operand), so they need not agree with `f64::min`/`f64::max` there — the
    /// `RealField` bound exposes the order but no NaN-aware `min`/`max`. The MV `Verdict` carrier is
    /// `[0, 1]` (`core.verdict.closure`), where every value is comparable and `NaN` does not occur,
    /// so on in-contract inputs `Min`/`Max` are the lattice meet/join.
    pub fn apply<R: RealField>(&self, a: R, b: R) -> R {
        match self {
            ArithmeticOperator::Add => a + b,
            ArithmeticOperator::Sub => a - b,
            ArithmeticOperator::Mul => a * b,
            ArithmeticOperator::Div => a / b,
            ArithmeticOperator::Min => {
                if a <= b {
                    a
                } else {
                    b
                }
            }
            ArithmeticOperator::Max => {
                if a >= b {
                    a
                } else {
                    b
                }
            }
        }
    }
}

use std::fmt;

impl fmt::Display for ArithmeticOperator {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            ArithmeticOperator::Add => write!(f, "Add"),
            ArithmeticOperator::Sub => write!(f, "Sub"),
            ArithmeticOperator::Mul => write!(f, "Mul"),
            ArithmeticOperator::Div => write!(f, "Div"),
            ArithmeticOperator::Min => write!(f, "Min"),
            ArithmeticOperator::Max => write!(f, "Max"),
        }
    }
}
