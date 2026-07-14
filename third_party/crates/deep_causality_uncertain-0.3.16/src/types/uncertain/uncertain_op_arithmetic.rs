/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ArithmeticOperator, Uncertain, UncertainNodeContent};
use std::ops::{Add, Div, Mul, Neg, Sub};

// Operator overloading is only implemented for f64 for now.
impl Add for Uncertain<f64> {
    type Output = Self;

    fn add(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Add,
            lhs: self.root_node,
            rhs: rhs.root_node,
        })
    }
}

impl Sub for Uncertain<f64> {
    type Output = Self;

    fn sub(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Sub,
            lhs: self.root_node,
            rhs: rhs.root_node,
        })
    }
}

impl Mul for Uncertain<f64> {
    type Output = Self;

    fn mul(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Mul,
            lhs: self.root_node,
            rhs: rhs.root_node,
        })
    }
}

impl Div for Uncertain<f64> {
    type Output = Self;

    fn div(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Div,
            lhs: self.root_node,
            rhs: rhs.root_node,
        })
    }
}

impl Neg for Uncertain<f64> {
    type Output = Self;

    fn neg(self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::NegationOp {
            operand: self.root_node,
        })
    }
}
