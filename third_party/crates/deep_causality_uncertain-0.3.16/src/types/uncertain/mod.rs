/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ProbabilisticType, UncertainNodeContent};

use std::marker::PhantomData;
use std::sync::atomic::{AtomicUsize, Ordering};

use deep_causality_ast::ConstTree;

mod uncertain_bool;
mod uncertain_bool_default;
mod uncertain_f64;
mod uncertain_f64_default;
mod uncertain_op_arithmetic;
mod uncertain_op_comparison;
mod uncertain_op_logic;
mod uncertain_part_eq;
mod uncertain_sampling;
mod uncertain_statistics;

// A single static counter for all Uncertain instances to generate unique IDs.
static NEXT_UNCERTAIN_ID: AtomicUsize = AtomicUsize::new(0);

/// A type representing a value with inherent uncertainty, modeled as a probability distribution.
#[derive(Clone, Debug)]
pub struct Uncertain<T: ProbabilisticType> {
    id: usize,
    root_node: ConstTree<UncertainNodeContent>,
    _phantom: PhantomData<T>,
}

impl<T: ProbabilisticType> Uncertain<T> {
    /// Creates a new `Uncertain` value from a computation graph represented by a root node.
    fn from_root_node(root_node: UncertainNodeContent) -> Self {
        Self {
            id: NEXT_UNCERTAIN_ID.fetch_add(1, Ordering::Relaxed),
            root_node: ConstTree::new(root_node),
            _phantom: PhantomData,
        }
    }

    pub fn conditional(condition: Uncertain<bool>, if_true: Self, if_false: Self) -> Self {
        Self::from_root_node(UncertainNodeContent::ConditionalOp {
            condition: condition.root_node,
            if_true: if_true.root_node,
            if_false: if_false.root_node,
        })
    }
}

impl<T: ProbabilisticType + Copy> Uncertain<T> {
    pub fn id(&self) -> usize {
        self.id
    }

    pub fn value(&self) -> T {
        match self.root_node.value() {
            UncertainNodeContent::Value(v) => T::from_sampled_value(*v).unwrap(),
            _ => T::default_value(),
        }
    }
}
