/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Defines binary arithmetic operations that take two f64 and return an f64.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ArithmeticOperator {
    Add,
    Sub,
    Mul,
    Div,
}

impl ArithmeticOperator {
    pub fn apply(&self, a: f64, b: f64) -> f64 {
        match self {
            ArithmeticOperator::Add => a + b,
            ArithmeticOperator::Sub => a - b,
            ArithmeticOperator::Mul => a * b,
            ArithmeticOperator::Div => a / b,
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
        }
    }
}
