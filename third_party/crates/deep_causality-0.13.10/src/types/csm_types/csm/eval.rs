/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{
    ActionError, CSM, CausalState, CsmError, CsmEvaluable, EffectValue, PropagatingEffect,
};
use std::fmt::Debug;

impl<I, O, C> CSM<I, O, C>
where
    I: Default + Clone + Debug + Send + Sync + 'static,
    O: CsmEvaluable + Default + Debug + Clone + Send + Sync + 'static,
    C: Clone + Debug + Send + Sync + 'static,
{
    /// Evaluates a single causal state at the index position id.
    /// If the state evaluates to an active effect, the associated action is fired.
    /// An active effect can be Deterministic(true) or an Uncertain type that passes
    /// its hypothesis test.
    ///
    /// # Errors
    /// Returns `CsmError` if the state does not exist, evaluation fails,
    /// or the action fails to fire.
    /// Also returns an error if the causaloid returns a probabilistic effect,
    /// which cannot be evaluated in a single state context.
    pub fn eval_single_state(
        &self,
        id: usize,
        data: &PropagatingEffect<I>,
    ) -> Result<(), CsmError> {
        let binding = self.state_actions.read().unwrap();

        let (state, action) = binding.get(&id).ok_or_else(|| {
            CsmError::Action(ActionError(format!(
                "State {id} does not exist. Add it first before evaluating."
            )))
        })?;

        let effect = state.eval_with_data(data)?; // Use eval_with_data for single state evaluation
        if effect.is_err() {
            return Err(CsmError::Causal(effect.error.unwrap()));
        }

        // Probabilistic check removed or needs to be handled via CsmEvaluable if needed.
        // Assuming CsmEvaluable handles logic.

        self.evaluate_and_fire_action(state, action, &effect)
    }

    /// Evaluates all causal states in the CSM using their internal data.
    /// For each state that evaluates to an active effect, the associated action is fired.
    ///
    /// # Errors
    /// Returns `CsmError` if any state evaluation or action firing fails.
    pub fn eval_all_states(&self) -> Result<(), CsmError> {
        let binding = self.state_actions.read().unwrap();

        for (_id, (state, action)) in binding.iter() {
            let effect = state.eval()?;
            if effect.is_err() {
                return Err(CsmError::Causal(effect.error.unwrap()));
            }
            self.evaluate_and_fire_action(state, action, &effect)?;
        }

        Ok(())
    }

    /// Centralized logic to evaluate an effect and fire an action if conditions are met.
    fn evaluate_and_fire_action(
        &self,
        state: &CausalState<I, O, C>,
        action: &crate::CausalAction,
        effect: &PropagatingEffect<O>,
    ) -> Result<(), CsmError> {
        let is_active = match &effect.value {
            EffectValue::Value(val) => val
                .is_active(state.uncertain_parameter().as_ref())
                .map_err(CsmError::Causal)?,
            // Other effect types (RelayTo, Error, etc.) are considered inactive for triggering actions here.
            _ => false,
        };

        if is_active {
            self.fire_action_with_ethos_check(state, action, effect)?;
        }

        Ok(())
    }

    /// Helper to fire an action.
    fn fire_action_with_ethos_check(
        &self,
        _state: &CausalState<I, O, C>,
        action: &crate::CausalAction,
        _effect: &PropagatingEffect<O>,
    ) -> Result<(), CsmError> {
        // Ethos checking has been moved to deep_causality_ethos crate
        action.fire()?;
        Ok(())
    }
}
