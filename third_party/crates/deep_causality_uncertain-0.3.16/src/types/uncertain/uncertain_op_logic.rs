/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::ops::{BitAnd, BitOr, BitXor, Not};

use crate::{LogicalOperator, Uncertain, UncertainNodeContent};

impl BitAnd for Uncertain<bool> {
    type Output = Self;
    fn bitand(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::LogicalOp {
            op: LogicalOperator::And,
            operands: vec![self.root_node.clone(), rhs.root_node.clone()],
        })
    }
}

impl BitOr for Uncertain<bool> {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::LogicalOp {
            op: LogicalOperator::Or,
            operands: vec![self.root_node.clone(), rhs.root_node.clone()],
        })
    }
}

impl Not for Uncertain<bool> {
    type Output = Self;
    fn not(self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::LogicalOp {
            op: LogicalOperator::Not,
            operands: vec![self.root_node.clone()],
        })
    }
}

impl BitXor for Uncertain<bool> {
    type Output = Self;

    fn bitxor(self, rhs: Self) -> Self::Output {
        Self::from_root_node(UncertainNodeContent::LogicalOp {
            op: LogicalOperator::XOR,
            operands: vec![self.root_node.clone(), rhs.root_node.clone()],
        })
    }
}
