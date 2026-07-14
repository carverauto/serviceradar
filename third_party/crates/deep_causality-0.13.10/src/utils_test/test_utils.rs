/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::*;
use deep_causality_haft::LogAddEntry;

use deep_causality_uncertain::{Uncertain, UncertainBool, UncertainF64};
use std::sync::{Arc, RwLock};

pub fn get_context() -> BaseContext {
    let id = 1;
    let name = "base context";
    let capacity = 10; // adjust as needed
    Context::with_capacity(id, name, capacity)
}

pub fn get_test_assumption_vec() -> Vec<Assumption> {
    let a1 = get_test_assumption();
    let a2 = get_test_assumption();
    let a3 = get_test_assumption();
    Vec::from_iter([a1, a2, a3])
}

pub fn get_test_obs_vec() -> Vec<Observation> {
    let o1 = Observation::new(0, 10.0, 1.0);
    let o2 = Observation::new(1, 10.0, 1.0);
    let o3 = Observation::new(2, 10.0, 1.0);
    let o4 = Observation::new(3, 12.0, 0.0);
    let o5 = Observation::new(4, 14.0, 0.0);
    Vec::from_iter([o1, o2, o3, o4, o5])
}

pub fn get_test_inf_vec() -> Vec<Inference> {
    let i1 = get_test_inferable(0, true);
    let i2 = get_test_inferable(1, false);
    Vec::from_iter([i1, i2])
}

pub fn get_deterministic_test_causality_vec() -> BaseCausaloidVec<f64, bool> {
    let q1 = get_test_causaloid_deterministic(1);
    let q2 = get_test_causaloid_deterministic(2);
    let q3 = get_test_causaloid_deterministic(3);
    Vec::from_iter([q1, q2, q3])
}
pub fn get_probabilistic_test_causality_vec() -> BaseCausaloidVec<f64, f64> {
    let q1 = get_test_causaloid_probabilistic();
    let q2 = get_test_causaloid_probabilistic();
    let q3 = get_test_causaloid_probabilistic();
    Vec::from_iter([q1, q2, q3])
}

pub fn get_uncertain_bool_test_causality_vec() -> BaseCausaloidVec<f64, UncertainBool> {
    let q1 = get_test_causaloid_uncertain_bool();
    let q2 = get_test_causaloid_uncertain_bool();
    let q3 = get_test_causaloid_uncertain_bool();
    Vec::from_iter([q1, q2, q3])
}

pub fn get_uncertain_float_test_causality_vec() -> BaseCausaloidVec<f64, UncertainF64> {
    let q1 = get_test_causaloid_uncertain_float();
    let q2 = get_test_causaloid_uncertain_float();
    let q3 = get_test_causaloid_uncertain_float();
    Vec::from_iter([q1, q2, q3])
}

pub fn get_test_single_data(val: NumericalValue) -> PropagatingEffect<NumericalValue> {
    PropagatingEffect::pure(val)
}

pub fn get_test_causaloid_deterministic_true() -> BaseCausaloid<bool, bool> {
    let description = "tests nothing; always returns true";
    fn causal_fn(_: bool) -> PropagatingEffect<bool> {
        let mut effect = PropagatingEffect::pure(true);
        effect.logs.add_entry("Just return true");
        effect
    }
    Causaloid::new(3, causal_fn, description)
}

pub fn get_test_causaloid_deterministic_false() -> BaseCausaloid<bool, bool> {
    let description = "tests nothing; always returns true";
    fn causal_fn(_: bool) -> PropagatingEffect<bool> {
        PropagatingEffect::pure(false)
    }
    Causaloid::new(3, causal_fn, description)
}

pub fn get_test_causaloid_probabilistic() -> BaseCausaloid<NumericalValue, f64> {
    let id: IdentificationValue = 3;
    let description = "tests whether data exceeds threshold of 0.55";

    fn causal_fn(obs: NumericalValue) -> PropagatingEffect<NumericalValue> {
        let threshold: NumericalValue = 0.55;
        let output = if obs.ge(&threshold) { 1.0 } else { 0.0 };
        PropagatingEffect::pure(output)
    }

    Causaloid::new(id, causal_fn, description)
}

pub fn get_test_causaloid_uncertain_bool() -> BaseCausaloid<f64, UncertainBool> {
    let description = "tests whether data exceeds threshold of 0.55 and returns uncertain bool";

    fn causal_fn(obs: NumericalValue) -> PropagatingEffect<UncertainBool> {
        let threshold: NumericalValue = 0.55;

        let output = if obs > threshold {
            Uncertain::<bool>::point(true)
        } else {
            Uncertain::<bool>::point(false)
        };
        PropagatingEffect::pure(output)
    }

    Causaloid::new(3, causal_fn, description)
}

pub fn get_test_causaloid_uncertain_float() -> BaseCausaloid<f64, UncertainF64> {
    let description = "tests whether data exceeds threshold of 0.55 and returns uncertain bool";
    fn causal_fn(obs: NumericalValue) -> PropagatingEffect<UncertainF64> {
        let threshold: NumericalValue = 0.55;
        let output = if obs > threshold {
            Uncertain::<f64>::point(1.0f64)
        } else {
            Uncertain::<f64>::point(0.0f64)
        };
        PropagatingEffect::pure(output)
    }

    Causaloid::new(3, causal_fn, description)
}

pub fn get_test_causaloid_deterministic(
    id: IdentificationValue,
) -> BaseCausaloid<NumericalValue, bool> {
    let description = "tests whether data exceeds threshold of 0.55";
    fn causal_fn(obs: NumericalValue) -> PropagatingEffect<bool> {
        let threshold: NumericalValue = 0.55;
        let output = obs.ge(&threshold);
        PropagatingEffect::pure(output)
    }

    Causaloid::new(id, causal_fn, description)
}

pub fn get_test_causaloid_probabilistic_bool_output() -> BaseCausaloid<NumericalValue, f64> {
    let id: IdentificationValue = 4;
    let description =
        "tests whether data exceeds threshold of 0.55 and returns bool probabilistically";

    fn causal_fn(obs: NumericalValue) -> PropagatingEffect<f64> {
        let threshold: NumericalValue = 0.55;
        let output = if obs.ge(&threshold) { 1.0 } else { 0.0 };
        PropagatingEffect::pure(output)
    }

    Causaloid::new(id, causal_fn, description)
}
pub fn get_test_causaloid_deterministic_with_context(
    context: BaseContext,
) -> BaseCausaloid<bool, bool> {
    let id: IdentificationValue = 1;
    let context = Arc::new(RwLock::new(context));
    let description = "Inverts any input";

    fn causal_fn_deterministic_with_context(
        obs: EffectValue<bool>,
        _state: (),
        context: Option<Arc<RwLock<BaseContext>>>,
    ) -> PropagatingProcess<bool, (), Arc<RwLock<BaseContext>>> {
        if context.is_none() {
            return PropagatingProcess::from_error(CausalityError(CausalityErrorEnum::Custom(
                "Context is missing".into(),
            )));
        }

        let input_val = obs.into_value().unwrap_or(false);

        // Cloning the Arc to keep a reference, then locking
        let ctx_ref = context.as_ref().unwrap().clone();
        let ctx = ctx_ref.read().expect("Failed to read context");

        let current_id = ctx.id();
        // Assuming context ID 1 is "true" logic
        if current_id == 1 {
            PropagatingProcess::pure(input_val)
        } else {
            PropagatingProcess::pure(!input_val)
        }
    }
    Causaloid::new_with_context(
        id,
        causal_fn_deterministic_with_context
            as fn(
                EffectValue<bool>,
                (),
                Option<Arc<RwLock<BaseContext>>>,
            ) -> PropagatingProcess<bool, (), Arc<RwLock<BaseContext>>>,
        context,
        description,
    )
}

pub fn get_test_causaloid_deterministic_input_output() -> BaseCausaloid<bool, bool> {
    let id: IdentificationValue = 2;
    let description = "Inverts any input";
    fn causal_fn(obs: bool) -> PropagatingEffect<bool> {
        PropagatingEffect::pure(!obs)
    }
    Causaloid::new(id, causal_fn, description)
}

pub fn get_test_error_causaloid() -> BaseCausaloid<bool, bool> {
    let id: IdentificationValue = 1;
    let description = "tests whether data exceeds threshold of 0.55";

    fn causal_fn(_: bool) -> PropagatingEffect<bool> {
        PropagatingEffect::from_error(CausalityError::new(CausalityErrorEnum::Custom(
            "Test error".into(),
        )))
    }

    Causaloid::new(id, causal_fn, description)
}

// BaseContext is a type alias for a basic context that can be used for testing
// It matches the type signature of the base causaloid also uses in these tests.
// See src/types/alias_types/csm_types for definition.
pub fn get_base_context() -> BaseContext {
    let id = 1;
    let name = "base context";
    let mut context = Context::with_capacity(id, name, 10);
    assert_eq!(context.size(), 0);

    let root = Root::new(id);
    let contextoid = Contextoid::new(id, ContextoidType::Root(root));
    let idx = context.add_node(contextoid).expect("Failed to add node");
    assert_eq!(idx, 0);
    assert_eq!(context.size(), 1);

    context
}

pub fn get_test_context() -> BaseContext {
    let mut context = Context::with_capacity(1, "Test-Context", 10);

    let id = 1;
    let root = Root::new(id);
    let contextoid = Contextoid::new(id, ContextoidType::Root(root));
    context.add_node(contextoid).expect("Failed to add node");

    context
}

pub fn get_test_inferable(id: IdentificationValue, inverse: bool) -> Inference {
    let question = "".to_string() as DescriptionValue;
    let all_obs = get_test_obs_vec();

    if inverse {
        let target_threshold = 11.0;
        let target_effect = 0.0;
        let observation = all_obs.percent_observation(target_threshold, target_effect);
        let threshold = 0.55;
        let effect = 0.0; // false
        let target = 0.0; // false

        Inference::new(id, question, observation, threshold, effect, target)
    } else {
        let target_threshold = 10.0;
        let target_effect = 1.0;
        let observation = all_obs.percent_observation(target_threshold, target_effect);
        let threshold = 0.55;
        let effect = 1.0; //true
        let target = 1.0; //true

        Inference::new(id, question, observation, threshold, effect, target)
    }
}

pub fn get_test_observation() -> Observation {
    Observation::new(0, 14.0, 1.0)
}

pub fn get_test_assumption() -> Assumption {
    let id: IdentificationValue = 1;
    let description: String = "Test assumption that data are there".to_string() as DescriptionValue;
    let assumption_fn: EvalFn = test_fn_has_data;

    Assumption::new(id, description, assumption_fn)
}

fn test_fn_has_data(data: &[PropagatingEffect<f64>]) -> Result<bool, AssumptionError> {
    Ok(!data.is_empty()) // Data is NOT empty i.e. true when it is 
}

pub fn get_test_assumption_false() -> Assumption {
    let id: IdentificationValue = 2;
    let description: String =
        "Test assumption that is always false".to_string() as DescriptionValue;
    let assumption_fn: EvalFn = test_fn_is_false;
    Assumption::new(id, description, assumption_fn)
}

fn test_fn_is_false(_data: &[PropagatingEffect<f64>]) -> Result<bool, AssumptionError> {
    Ok(false)
}

pub fn get_test_assumption_error() -> Assumption {
    let id: IdentificationValue = 2;
    let description: String =
        "Test assumption that raises an error".to_string() as DescriptionValue;
    let assumption_fn: EvalFn = test_fn_is_error;
    Assumption::new(id, description, assumption_fn)
}

fn test_fn_is_error(_data: &[PropagatingEffect<f64>]) -> Result<bool, AssumptionError> {
    Err(AssumptionError::AssumptionFailed(String::from(
        "Test error",
    )))
}

pub fn get_test_num_array() -> [NumericalValue; 10] {
    [8.4, 8.5, 9.1, 9.3, 9.4, 9.5, 9.7, 9.7, 9.9, 9.9]
}

pub fn get_test_causaloid(id: IdentificationValue) -> BaseCausaloid<f64, bool> {
    let description = "tests whether data exceeds threshold of 0.55";

    fn causal_fn(evidence: f64) -> PropagatingEffect<bool> {
        let mut log = EffectLog::new();
        log.add_entry(&format!("Processing evidence: {}", evidence));

        if evidence.is_sign_negative() {
            log.add_entry("Observation is negative, returning error.");
            let mut effect = PropagatingEffect::from_error(CausalityError::new(
                CausalityErrorEnum::Custom("Observation is negative".into()),
            ));
            effect.logs = log;
            return effect;
        }

        let threshold: NumericalValue = 0.55;
        let is_active = evidence.ge(&threshold);
        log.add_entry(&format!(
            "Evidence {} >= threshold {}: {}",
            evidence, threshold, is_active
        ));

        let mut effect = PropagatingEffect::pure(is_active);
        effect.logs = log;
        effect
    }

    Causaloid::new(id, causal_fn, description)
}

pub fn get_test_causaloid_num_input_output(id: IdentificationValue) -> BaseCausaloid<f64, f64> {
    let description = "tests whether data exceeds threshold of 0.55";

    fn causal_fn(evidence: f64) -> PropagatingEffect<f64> {
        let mut log = EffectLog::new();
        log.add_entry(&format!("Processing evidence: {}", evidence));

        if evidence.is_sign_negative() {
            log.add_entry("Observation is negative, returning error.");
            let mut effect = PropagatingEffect::from_error(CausalityError::new(
                CausalityErrorEnum::Custom("Observation is negative".into()),
            ));
            effect.logs = log;
            return effect;
        }

        let threshold: NumericalValue = 0.55;
        let is_active = if evidence.ge(&threshold) { 1.0 } else { 0.0 };
        log.add_entry(&format!(
            "Evidence {} >= threshold {}: {}",
            evidence, threshold, is_active
        ));

        let mut effect = PropagatingEffect::pure(is_active);
        effect.logs = log;
        effect
    }

    Causaloid::new(id, causal_fn, description)
}

pub fn generate_sample_data<const N: usize>() -> [f64; N] {
    [0.99; N]
}
