/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalityError, Causaloid};
use deep_causality_core::{EffectValue, PropagatingEffect, PropagatingProcess};
use deep_causality_haft::LogAddEntry;
use std::fmt::Debug;

/// Represents the execution step in a `Causaloid::Singleton` monadic chain.
///
/// This function executes the core causal function (`causal_fn` or `context_causal_fn`)
/// of the causaloid.
///
/// # Arguments
/// * `input`: The specific input value of type `I`.
/// * `causaloid`: A reference to the causaloid containing the function to execute.
///
/// # Returns
/// A `PropagatingEffect` containing either the resulting output
/// value of type `O` or an error.
pub(super) fn execute_causal_logic<I, O, PS, C>(
    input: I,
    causaloid: &Causaloid<I, O, PS, C>,
) -> PropagatingEffect<O>
where
    I: Default + Clone,
    O: Default + Clone + Debug,
    PS: Default + Clone,
    C: Clone,
{
    if let Some(context_fn) = &causaloid.context_causal_fn {
        if let Some(context) = causaloid.context.as_ref() {
            // context_fn signature: fn(EffectValue<I>, PS, Option<C>) -> PropagatingProcess<O, PS, C>
            // We invoke it with default state and the context.
            // The result is PropagatingProcess<O, PS, C>.
            // We need to convert it to PropagatingEffect<O>.

            let ev = EffectValue::from(input);
            let process = context_fn(ev, PS::default(), Some(context.clone()));

            // Convert PropagatingProcess to PropagatingEffect, preserving logs.
            // Convert PropagatingProcess to PropagatingEffect, preserving logs.
            let mut effect = if let Some(error) = process.error {
                PropagatingEffect::from_error(error)
            } else if process.value.is_none() {
                PropagatingEffect::from_error(CausalityError(
                    deep_causality_core::CausalityErrorEnum::Custom(
                        "execute_causal_logic: context_fn returned None value and no error".into(),
                    ),
                ))
            } else {
                PropagatingEffect::from_effect_value(process.value)
            };
            effect.logs = process.logs;
            effect
        } else {
            PropagatingEffect::from_error(CausalityError(
                deep_causality_core::CausalityErrorEnum::Custom(
                    "Causaloid::evaluate: context is None".into(),
                ),
            ))
        }
    } else if let Some(causal_fn) = &causaloid.causal_fn {
        causal_fn(input)
    } else {
        let err_msg = format!(
            "Causaloid {} is missing both causal_fn and context_causal_fn",
            causaloid.id
        );
        PropagatingEffect::from_error(CausalityError(
            deep_causality_core::CausalityErrorEnum::Custom(err_msg),
        ))
    }
}

/// Logs the input to a causaloid.
///
/// # Arguments
/// * `input`: The input value of type `I`.
/// * `id`: The unique identifier of the causaloid.
///
/// # Returns
/// A `PropagatingEffect` containing the input value and a log entry recording it.
pub(super) fn log_input<I>(input: I, id: u64) -> PropagatingEffect<I>
where
    I: Debug + Clone + Default,
{
    let mut effect = PropagatingEffect::pure(input.clone());
    // Format must match expectation: "Causaloid {}: Incoming effect: {:?}"
    let ev = EffectValue::from(input);
    effect
        .logs
        .add_entry(&format!("Causaloid {}: Incoming effect: {:?}", id, ev));
    effect
}

/// Stateful sibling of [`execute_causal_logic`].
///
/// Threads `state` and `context` from the caller into the causaloid's stored
/// closure (preferring the context-aware variant when present) and returns the
/// resulting `PropagatingProcess<O, S, C>` without conversion. Unlike the
/// stateless helper, this function does **not** call `S::default()` and does
/// **not** discard the `state` carried on the closure's output.
///
/// Behaviour:
/// * If `causaloid.context_causal_fn` is set, the closure is invoked with
///   `(EffectValue::from(input), state, context)` and its returned process is
///   returned to the caller intact (logs preserved, state preserved).
/// * Otherwise, if the stateless `causaloid.causal_fn` is set, it is invoked on
///   the value and the resulting `PropagatingEffect<O>` is lifted into a
///   `PropagatingProcess<O, S, C>` whose `state` and `context` fields are the
///   pass-through arguments supplied by the caller.
/// * If neither closure is set, an error process is returned with the caller's
///   `state` and `context` preserved.
pub(super) fn execute_causal_logic_stateful<I, O, PS, C>(
    input: I,
    state: PS,
    context: Option<C>,
    causaloid: &Causaloid<I, O, PS, C>,
) -> PropagatingProcess<O, PS, C>
where
    I: Default + Clone,
    O: Default + Clone + Debug,
    PS: Default + Clone,
    C: Clone,
{
    if let Some(context_fn) = &causaloid.context_causal_fn {
        let ev = EffectValue::from(input);
        // Prefer the caller-supplied context; fall back to the causaloid's own
        // stored context only if the caller passed `None`. This mirrors the
        // existing context-discovery behaviour of `execute_causal_logic` while
        // honouring the caller's explicit choice when one is given.
        let effective_ctx = context.or_else(|| causaloid.context.clone());
        return context_fn(ev, state, effective_ctx);
    }

    if let Some(causal_fn) = &causaloid.causal_fn {
        let stateless: PropagatingEffect<O> = causal_fn(input);
        return PropagatingProcess {
            value: stateless.value,
            state,
            context,
            error: stateless.error,
            logs: stateless.logs,
        };
    }

    let err_msg = format!(
        "Causaloid {} is missing both causal_fn and context_causal_fn",
        causaloid.id
    );
    PropagatingProcess {
        value: EffectValue::None,
        state,
        context,
        error: Some(CausalityError(
            deep_causality_core::CausalityErrorEnum::Custom(err_msg),
        )),
        logs: Default::default(),
    }
}

/// Stateful sibling of [`log_input`]. Records the input on the process log
/// while preserving the caller's `state` and `context`.
pub(super) fn log_input_stateful<I, PS, C>(
    input: I,
    id: u64,
    state: PS,
    context: Option<C>,
) -> PropagatingProcess<I, PS, C>
where
    I: Debug + Clone + Default,
    PS: Clone,
    C: Clone,
{
    let ev = EffectValue::from(input.clone());
    let mut process: PropagatingProcess<I, PS, C> = PropagatingProcess {
        value: EffectValue::Value(input),
        state,
        context,
        error: None,
        logs: Default::default(),
    };
    process
        .logs
        .add_entry(&format!("Causaloid {}: Incoming effect: {:?}", id, ev));
    process
}

/// Stateful sibling of [`log_output`]. Records the output on the process log
/// while preserving the caller's `state` and `context`.
pub(super) fn log_output_stateful<O, PS, C>(
    output: O,
    id: u64,
    state: PS,
    context: Option<C>,
) -> PropagatingProcess<O, PS, C>
where
    O: Debug + Clone + Default,
    PS: Clone,
    C: Clone,
{
    let ev = EffectValue::from(output.clone());
    let mut process: PropagatingProcess<O, PS, C> = PropagatingProcess {
        value: EffectValue::Value(output),
        state,
        context,
        error: None,
        logs: Default::default(),
    };
    process
        .logs
        .add_entry(&format!("Causaloid {}: Outgoing effect: {:?}", id, ev));
    process
}

/// Logs the output from a causaloid.
///
/// # Arguments
/// * `output`: The output value of type `O`.
/// * `id`: The unique identifier of the causaloid.
///
/// # Returns
/// A `PropagatingEffect` containing the output value and a log entry recording it.
pub(super) fn log_output<O>(output: O, id: u64) -> PropagatingEffect<O>
where
    O: Debug + Clone + Default,
{
    let mut effect = PropagatingEffect::pure(output.clone());
    // Format must match expectation: "Causaloid {}: Outgoing effect: {:?}"
    let ev = EffectValue::from(output);
    effect
        .logs
        .add_entry(&format!("Causaloid {}: Outgoing effect: {:?}", id, ev));
    effect
}
