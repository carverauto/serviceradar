/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CSM, CSMMap, CausalAction, CausalState, CsmEvaluable, StateAction, UpdateError};
use std::fmt::Debug;

impl<I, O, C> CSM<I, O, C>
where
    I: Default + Clone,
    O: CsmEvaluable + Default + Debug + Clone,
    C: Clone,
{
    /// Updates a causal state using the state's internal ID.
    /// Returns UpdateError if the state does not exist.
    pub fn update_single_state(
        &self,
        state_action: StateAction<I, O, C>,
    ) -> Result<(), UpdateError> {
        let state_id = state_action.0.id();

        // Check if the key exists, if not return error
        if !self.state_actions.read().unwrap().contains_key(&state_id) {
            return Err(UpdateError(format!(
                "State {state_id} does not exist. Add it first before updating."
            )));
        }

        // Update state/action using internal ID
        self.state_actions
            .write()
            .unwrap()
            .insert(state_id, state_action);

        Ok(())
    }

    /// Updates all causal state with a new state collection.
    /// Note, this operation erases all previous states in the CSM by generating a new collection.
    /// Returns UpdateError if the update operation failed.
    pub fn update_all_states(
        &self,
        state_actions: &[(&CausalState<I, O, C>, &CausalAction)],
    ) -> Result<(), UpdateError> {
        let mut state_map = CSMMap::with_capacity(state_actions.len());

        for (state, action) in state_actions {
            state_map.insert(state.id(), ((*state).clone(), (*action).clone()));
        }

        // Replace the existing map with the newly generated one.
        *self.state_actions.write().unwrap() = state_map;
        Ok(())
    }
}
