/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ArithmeticOperator, ComparisonOperator, Uncertain, UncertainNodeContent};
use deep_causality_ast::ConstTree;

// Note: We do not implement the standard `PartialOrd` and `PartialEq` traits
// because their signatures return `bool`, which is misleading for uncertain values.
// Instead, we provide methods that correctly return a new `Uncertain<bool>`.

impl Uncertain<f64> {
    pub fn greater_than(&self, threshold: f64) -> Uncertain<bool> {
        Uncertain::from_root_node(UncertainNodeContent::ComparisonOp {
            op: ComparisonOperator::GreaterThan,
            threshold,
            operand: self.root_node.clone(),
        })
    }

    pub fn less_than(&self, threshold: f64) -> Uncertain<bool> {
        Uncertain::from_root_node(UncertainNodeContent::ComparisonOp {
            op: ComparisonOperator::LessThan,
            threshold,
            operand: self.root_node.clone(),
        })
    }

    pub fn equals(&self, threshold: f64) -> Uncertain<bool> {
        Uncertain::from_root_node(UncertainNodeContent::ComparisonOp {
            op: ComparisonOperator::EqualTo,
            threshold,
            operand: self.root_node.clone(),
        })
    }

    pub fn gt_uncertain(&self, other: &Self) -> Uncertain<bool> {
        Uncertain::from_root_node(UncertainNodeContent::ComparisonOp {
            op: ComparisonOperator::GreaterThan,
            threshold: 0.0,
            operand: ConstTree::new(UncertainNodeContent::ArithmeticOp {
                op: ArithmeticOperator::Sub,
                lhs: self.root_node.clone(),
                rhs: other.root_node.clone(),
            }),
        })
    }

    pub fn lt_uncertain(&self, other: &Self) -> Uncertain<bool> {
        Uncertain::from_root_node(UncertainNodeContent::ComparisonOp {
            op: ComparisonOperator::LessThan,
            threshold: 0.0,
            operand: ConstTree::new(UncertainNodeContent::ArithmeticOp {
                op: ArithmeticOperator::Sub,
                lhs: self.root_node.clone(),
                rhs: other.root_node.clone(),
            }),
        })
    }

    pub fn eq_uncertain(&self, other: &Self) -> Uncertain<bool> {
        Uncertain::from_root_node(UncertainNodeContent::ComparisonOp {
            op: ComparisonOperator::EqualTo,
            threshold: 0.0,
            operand: ConstTree::new(UncertainNodeContent::ArithmeticOp {
                op: ArithmeticOperator::Sub,
                lhs: self.root_node.clone(),
                rhs: other.root_node.clone(),
            }),
        })
    }

    /// Check if value is approximately equal within tolerance
    pub fn approx_eq(&self, target: f64, tolerance: f64) -> Uncertain<bool> {
        self.map_to_bool(move |x| (x - target).abs() <= tolerance)
    }

    /// Check if value is within a range
    pub fn within_range(&self, min: f64, max: f64) -> Uncertain<bool> {
        self.map_to_bool(move |x| x >= min && x <= max)
    }
}
