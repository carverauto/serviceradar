/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Causaloid, PropagatingEffect, UncertainParameter};
use std::fmt::Debug;
use std::marker::PhantomData;
mod display;
mod eval;
mod getter;

/// A `CausalState` represents a state in a causal state machine (CSM) that can be evaluated
/// based on causal conditions.
///
/// In a CSM, states are paired with actions. When a state's conditions are met (evaluated to true),
/// the associated action is triggered.
///
/// # Purpose
/// `CausalState` encapsulates a reference to a causaloid that defines when the state should be
/// considered active, along with:
/// - An identifier for the state
/// - A version number for tracking changes
/// - Data that can be used for evaluation
///
/// # Usage
/// `CausalState` is typically used in conjunction with `CausalAction` in a state-action pair
/// within a causal state machine (CSM). The CSM evaluates states, and when conditions are met,
/// fires the associated actions.
///
#[derive(Clone, Debug)]
pub struct CausalState<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    /// Unique identifier for the state
    id: usize,
    /// Version number for tracking changes to the state
    version: usize,
    /// Numerical data used for state evaluation
    data: PropagatingEffect<I>,
    /// The `Causaloid` managed by this state.
    ///
    /// This represents the active causal unit (logic) currently associated with
    /// the state machine's execution context.
    causaloid: Causaloid<I, O, (), C>,
    /// Optional parameters for evaluating uncertain effects.
    uncertain_parameter: Option<UncertainParameter>,
    /// PhantomData to bind generic type `C`.
    _phantom: PhantomData<C>,
}

impl<I, O, C> CausalState<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    pub fn new(
        id: usize,
        version: usize,
        data: PropagatingEffect<I>,
        causaloid: Causaloid<I, O, (), C>,
        uncertain_parameter: Option<UncertainParameter>,
    ) -> Self {
        Self {
            id,
            version,
            data,
            causaloid,
            uncertain_parameter,
            _phantom: PhantomData,
        }
    }
}
