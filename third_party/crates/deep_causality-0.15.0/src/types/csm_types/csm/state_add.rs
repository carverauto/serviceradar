/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CSM, CsmEvaluable, StateAction, UpdateError};
use std::fmt::Debug;

impl<I, O, C> CSM<I, O, C>
where
    I: Default + Clone,
    O: CsmEvaluable + Default + Debug + Clone,
    C: Clone,
{
    /// Inserts a new state action using the state's internal ID.
    /// Returns UpdateError if a state with that ID already exists.
    pub fn add_single_state(&self, state_action: StateAction<I, O, C>) -> Result<(), UpdateError> {
        let state_id = state_action.0.id();

        // Check if the key exists, if so return error
        if self.state_actions.read().unwrap().contains_key(&state_id) {
            return Err(UpdateError(format!("State {state_id} already exists.")));
        }

        // Insert the new state/action using internal ID
        self.state_actions
            .write()
            .unwrap()
            .insert(state_id, state_action);

        Ok(())
    }
}
