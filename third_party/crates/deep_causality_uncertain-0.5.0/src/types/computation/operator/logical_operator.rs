/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt;

/// Defines logical operations that take bool(s) and return a bool.
#[derive(Debug, Clone, Copy, PartialOrd, PartialEq)]
pub enum LogicalOperator {
    And, // true if and only if A and B are true
    Or,  // true if and only if A or B is true
    Not, // Note: `Not` is unary, which will be handled by the sampler logic.
    NOR, // true if and only if all of its inputs are false
    XOR, //  true if and only if one of its operands is true.
}

impl LogicalOperator {
    pub fn apply(&self, a: bool, b: bool) -> bool {
        match self {
            LogicalOperator::And => a && b,
            LogicalOperator::Or => a || b,
            LogicalOperator::Not => !a, // For `Not`, `b` is ignored as it's a unary operation.
            LogicalOperator::NOR => !(a || b),
            LogicalOperator::XOR => a ^ b,
        }
    }
}

impl fmt::Display for LogicalOperator {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            LogicalOperator::And => write!(f, "AND"),
            LogicalOperator::Or => write!(f, "OR"),
            LogicalOperator::Not => write!(f, "NOT"),
            LogicalOperator::NOR => write!(f, "NOR"),
            LogicalOperator::XOR => write!(f, "XOR"),
        }
    }
}
