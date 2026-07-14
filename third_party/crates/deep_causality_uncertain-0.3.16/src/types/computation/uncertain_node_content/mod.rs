/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt::Debug;
use std::sync::Arc;

use deep_causality_ast::ConstTree;

use crate::{
    ArithmeticOperator, ComparisonOperator, DistributionEnum, LogicalOperator, SampledValue,
};

pub trait SampledFmapFn: Send + Sync + 'static {
    fn call(&self, input: SampledValue) -> SampledValue;
}

impl<F> SampledFmapFn for F
where
    F: Fn(SampledValue) -> SampledValue + Send + Sync + 'static,
{
    fn call(&self, input: SampledValue) -> SampledValue {
        self(input)
    }
}

pub trait SampledBindFn: Send + Sync + 'static {
    fn call(&self, input: SampledValue) -> ConstTree<UncertainNodeContent>;
}

impl<F> SampledBindFn for F
where
    F: Fn(SampledValue) -> ConstTree<UncertainNodeContent> + Send + Sync + 'static,
{
    fn call(&self, input: SampledValue) -> ConstTree<UncertainNodeContent> {
        self(input)
    }
}

#[derive(Clone)]
pub enum UncertainNodeContent {
    // Leaf nodes
    Value(SampledValue),
    DistributionF64(DistributionEnum<f64>),
    DistributionBool(DistributionEnum<bool>),

    // HKT Operations
    PureOp {
        value: SampledValue,
    },
    FmapOp {
        func: Arc<dyn SampledFmapFn>,
        operand: ConstTree<UncertainNodeContent>,
    },
    ApplyOp {
        func: Arc<dyn SampledFmapFn>,
        arg: ConstTree<UncertainNodeContent>,
    },
    BindOp {
        func: Arc<dyn SampledBindFn>,
        operand: ConstTree<UncertainNodeContent>,
    },

    // Original ComputationNode operations, adapted to use ConstTree and SampledValue
    ArithmeticOp {
        op: ArithmeticOperator,
        lhs: ConstTree<UncertainNodeContent>,
        rhs: ConstTree<UncertainNodeContent>,
    },
    ComparisonOp {
        op: ComparisonOperator,
        threshold: f64,
        operand: ConstTree<UncertainNodeContent>,
    },
    LogicalOp {
        op: LogicalOperator,
        operands: Vec<ConstTree<UncertainNodeContent>>,
    },
    FunctionOpF64 {
        func: Arc<dyn Fn(f64) -> f64 + Send + Sync>,
        operand: ConstTree<UncertainNodeContent>,
    },
    FunctionOpBool {
        func: Arc<dyn Fn(f64) -> bool + Send + Sync>,
        operand: ConstTree<UncertainNodeContent>,
    },
    NegationOp {
        operand: ConstTree<UncertainNodeContent>,
    },
    ConditionalOp {
        condition: ConstTree<UncertainNodeContent>,
        if_true: ConstTree<UncertainNodeContent>,
        if_false: ConstTree<UncertainNodeContent>,
    },
}

impl Debug for UncertainNodeContent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            UncertainNodeContent::Value(v) => write!(f, "Value({:?})", v),
            UncertainNodeContent::DistributionF64(d) => write!(f, "DistributionF64({:?})", d),
            UncertainNodeContent::DistributionBool(d) => write!(f, "DistributionBool({:?})", d),
            UncertainNodeContent::PureOp { value } => write!(f, "PureOp {{ value: {:?} }}", value),
            UncertainNodeContent::FmapOp { func: _, operand } => {
                write!(f, "FmapOp {{ func: Fn, operand: {:?} }}", operand)
            }
            UncertainNodeContent::ApplyOp { func: _, arg } => {
                write!(f, "ApplyOp {{ func: Fn, arg: {:?} }}", arg)
            }
            UncertainNodeContent::BindOp { func: _, operand } => {
                write!(f, "BindOp {{ func: Fn, operand: {:?} }}", operand)
            }
            UncertainNodeContent::ArithmeticOp { op, lhs, rhs } => write!(
                f,
                "ArithmeticOp {{ op: {:?}, lhs: {:?}, rhs: {:?} }}",
                op, lhs, rhs
            ),
            UncertainNodeContent::ComparisonOp {
                op,
                threshold,
                operand,
            } => write!(
                f,
                "ComparisonOp {{ op: {:?}, threshold: {:?}, operand: {:?} }}",
                op, threshold, operand
            ),
            UncertainNodeContent::LogicalOp { op, operands } => {
                write!(f, "LogicalOp {{ op: {:?}, operands: {:?} }}", op, operands)
            }
            UncertainNodeContent::FunctionOpF64 { func: _, operand } => {
                write!(f, "FunctionOpF64 {{ func: Fn, operand: {:?} }}", operand)
            }
            UncertainNodeContent::FunctionOpBool { func: _, operand } => {
                write!(f, "FunctionOpBool {{ func: Fn, operand: {:?} }}", operand)
            }
            UncertainNodeContent::NegationOp { operand } => {
                write!(f, "NegationOp {{ operand: {:?} }}", operand)
            }
            UncertainNodeContent::ConditionalOp {
                condition,
                if_true,
                if_false,
            } => write!(
                f,
                "ConditionalOp {{ condition: {:?}, if_true: {:?}, if_false: {:?} }}",
                condition, if_true, if_false
            ),
        }
    }
}

impl PartialEq for UncertainNodeContent {
    fn eq(&self, other: &Self) -> bool {
        // This is a simplified PartialEq. For a full comparison, deep equality of ConstTree would be needed,
        // and function pointers cannot be compared directly. This is mainly for testing structural equality.
        match (self, other) {
            (UncertainNodeContent::Value(v1), UncertainNodeContent::Value(v2)) => v1 == v2,
            (
                UncertainNodeContent::DistributionF64(d1),
                UncertainNodeContent::DistributionF64(d2),
            ) => d1 == d2,
            (
                UncertainNodeContent::DistributionBool(d1),
                UncertainNodeContent::DistributionBool(d2),
            ) => d1 == d2,
            (
                UncertainNodeContent::PureOp { value: v1 },
                UncertainNodeContent::PureOp { value: v2 },
            ) => v1 == v2,
            // For operations involving functions, we can only compare the structure and operands, not the functions themselves.
            (
                UncertainNodeContent::FmapOp { operand: o1, .. },
                UncertainNodeContent::FmapOp { operand: o2, .. },
            ) => o1 == o2,
            (
                UncertainNodeContent::ApplyOp { arg: a1, .. },
                UncertainNodeContent::ApplyOp { arg: a2, .. },
            ) => a1 == a2,
            (
                UncertainNodeContent::BindOp { operand: o1, .. },
                UncertainNodeContent::BindOp { operand: o2, .. },
            ) => o1 == o2,
            (
                UncertainNodeContent::ArithmeticOp {
                    op: op1,
                    lhs: l1,
                    rhs: r1,
                },
                UncertainNodeContent::ArithmeticOp {
                    op: op2,
                    lhs: l2,
                    rhs: r2,
                },
            ) => op1 == op2 && l1 == l2 && r1 == r2,
            (
                UncertainNodeContent::ComparisonOp {
                    op: op1,
                    threshold: t1,
                    operand: o1,
                },
                UncertainNodeContent::ComparisonOp {
                    op: op2,
                    threshold: t2,
                    operand: o2,
                },
            ) => op1 == op2 && t1 == t2 && o1 == o2,
            (
                UncertainNodeContent::LogicalOp {
                    op: op1,
                    operands: ops1,
                },
                UncertainNodeContent::LogicalOp {
                    op: op2,
                    operands: ops2,
                },
            ) => op1 == op2 && ops1 == ops2,
            (
                UncertainNodeContent::FunctionOpF64 { operand: o1, .. },
                UncertainNodeContent::FunctionOpF64 { operand: o2, .. },
            ) => o1 == o2,
            (
                UncertainNodeContent::FunctionOpBool { operand: o1, .. },
                UncertainNodeContent::FunctionOpBool { operand: o2, .. },
            ) => o1 == o2,
            (
                UncertainNodeContent::NegationOp { operand: o1 },
                UncertainNodeContent::NegationOp { operand: o2 },
            ) => o1 == o2,
            (
                UncertainNodeContent::ConditionalOp {
                    condition: c1,
                    if_true: t1,
                    if_false: f1,
                },
                UncertainNodeContent::ConditionalOp {
                    condition: c2,
                    if_true: t2,
                    if_false: f2,
                },
            ) => c1 == c2 && t1 == t2 && f1 == f2,
            _ => false,
        }
    }
}
