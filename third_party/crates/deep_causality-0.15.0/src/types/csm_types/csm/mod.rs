/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod eval;
mod state_add;
mod state_remove;
mod state_update;

use crate::CsmEvaluable;
use crate::{CSMMap, CausalAction, CausalState};
use std::fmt::Debug;
use std::sync::{Arc, RwLock};

/// # Causal State Machine (CSM)
///
/// A Causal State Machine (CSM) is a structure that manages relationships between causal states and actions.
/// It provides a mechanism for evaluating states based on input data and triggering associated actions
/// when specific conditions are met.
///
/// ## Purpose
///
/// The CSM is designed to model systems where different states can trigger specific actions when
/// certain conditions are met. It's particularly useful for:
///
/// - Event-driven systems where actions should be triggered based on state changes
/// - Monitoring systems that need to respond to specific conditions
/// - Control systems that need to take actions based on sensor readings
/// - Any system where cause-effect relationships need to be modeled and evaluated
///
/// ## How It Works
///
/// 1. The CSM maintains a collection of causal states paired with actions
/// 2. Each causal state contains a causaloid that defines when the state should trigger its action
/// 3. When data is fed into the CSM, it evaluates the relevant states
/// 4. If a state's conditions are met (evaluated to true), the associated action is triggered
///
/// ## Usage
///
/// The CSM is typically used by:
///
/// 1. Creating causal states with appropriate causaloids that define trigger conditions
/// 2. Creating actions that should be executed when states are triggered
/// 3. Initializing a CSM with state-action pairs
/// 4. Feeding data into the CSM for evaluation
///
/// See the example in `examples/csm/src/main.rs` for a practical implementation.
pub struct CSM<I, O, C>
where
    I: Default + Clone,
    O: CsmEvaluable + Default + Debug + Clone,
    C: Clone,
{
    state_actions: Arc<RwLock<CSMMap<I, O, C>>>,
}

impl<I, O, C> CSM<I, O, C>
where
    I: Default + Clone,
    O: CsmEvaluable + Default + Debug + Clone,
    C: Clone,
{
    /// Constructs a new CSM.
    pub fn new(state_actions: &[(&CausalState<I, O, C>, &CausalAction)]) -> Self {
        let mut map = CSMMap::with_capacity(state_actions.len());

        for (state, action) in state_actions {
            map.insert(state.id(), ((*state).clone(), (*action).clone()));
        }

        Self {
            state_actions: Arc::new(RwLock::new(map)),
        }
    }

    /// Returns the number of elements in the CSM.
    pub fn len(&self) -> usize {
        self.state_actions.read().unwrap().len()
    }

    /// Returns true if the CSM contains no elements.
    pub fn is_empty(&self) -> bool {
        self.state_actions.read().unwrap().is_empty()
    }
}
