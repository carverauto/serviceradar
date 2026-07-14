/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ArithmeticOperator, ProbabilisticType, Uncertain, UncertainNodeContent};
use deep_causality_algebra::RealField;
use std::ops::{Add, Div, Mul, Neg, Sub};

// Arithmetic operator overloading for the real-scalar instantiations (`f64`, `Float106`).
// The nodes are precision-agnostic — they only thread `ConstTree`s — and the sampler
// dispatches per `SampledValue` variant. The `RealField` bound keeps the impls off
// `Uncertain<bool>`, where arithmetic is meaningless.
impl<T: ProbabilisticType + RealField> Add for Uncertain<T> {
    type Output = Self;

    fn add(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Add,
            lhs: self.root_node,
            rhs: rhs.root_node,
        })
    }
}

impl<T: ProbabilisticType + RealField> Sub for Uncertain<T> {
    type Output = Self;

    fn sub(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Sub,
            lhs: self.root_node,
            rhs: rhs.root_node,
        })
    }
}

impl<T: ProbabilisticType + RealField> Mul for Uncertain<T> {
    type Output = Self;

    fn mul(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Mul,
            lhs: self.root_node,
            rhs: rhs.root_node,
        })
    }
}

impl<T: ProbabilisticType + RealField> Div for Uncertain<T> {
    type Output = Self;

    fn div(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Div,
            lhs: self.root_node,
            rhs: rhs.root_node,
        })
    }
}

impl<T: ProbabilisticType + RealField> Neg for Uncertain<T> {
    type Output = Self;

    fn neg(self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::NegationOp {
            operand: self.root_node,
        })
    }
}
