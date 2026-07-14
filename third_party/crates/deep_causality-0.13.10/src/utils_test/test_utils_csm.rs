/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::utils_test::test_utils;
use crate::*;
use deep_causality_haft::LogAddEntry;
use std::sync::{Arc, Mutex};

// EffectEthos type has been moved to deep_causality_ethos crate

pub fn state_action() -> Result<(), ActionError> {
    Ok(())
}

pub fn get_test_action() -> CausalAction {
    CausalAction::new(state_action, "Test action", 1)
}

pub fn get_test_error_action() -> CausalAction {
    fn err_state_action() -> Result<(), ActionError> {
        Err(ActionError("Error".to_string()))
    }

    CausalAction::new(err_state_action, "Test action", 1)
}

// Causaloid that returns a non-deterministic effect
pub fn get_test_probabilistic_causaloid() -> BaseCausaloid<f64, f64> {
    fn causal_fn(_: f64) -> PropagatingEffect<f64> {
        let log = EffectLog::new();
        let mut effect = PropagatingEffect::pure(0.5);
        effect.logs = log;
        effect
    }
    Causaloid::new(99, causal_fn, "Probabilistic Causaloid")
}

pub fn get_test_error_causaloid() -> BaseCausaloid<bool, bool> {
    fn causal_fn(_: bool) -> PropagatingEffect<bool> {
        PropagatingEffect::from_error(CausalityError::new(CausalityErrorEnum::Custom(
            "Error".to_string(),
        )))
    }
    Causaloid::new(78, causal_fn, "Error Causaloid")
}

// get_effect_ethos function has been removed since EffectEthos moved to deep_causality_ethos crate

pub fn get_test_causaloid(with_context: bool) -> BaseCausaloid<bool, bool> {
    if with_context {
        let context = test_utils::get_context(); // Use the helper to get a base context
        test_utils::get_test_causaloid_deterministic_with_context(context)
    } else {
        fn causal_fn(_effect: bool) -> PropagatingEffect<bool> {
            let mut log = EffectLog::new();
            log.add_entry("Just return true");
            let mut effect = PropagatingEffect::pure(true);
            effect.logs = log;
            effect
        }
        Causaloid::new(1, causal_fn, "Test Causaloid")
    }
}

pub fn get_test_action_with_tracker() -> CausalAction {
    fn action() -> Result<(), ActionError> {
        let tracker: Arc<Mutex<bool>> = Arc::new(Mutex::new(false));
        let mut lock = tracker.lock().unwrap();
        *lock = true;
        Ok(())
    }

    CausalAction::new(action, "Tracked Action", 1)
}
