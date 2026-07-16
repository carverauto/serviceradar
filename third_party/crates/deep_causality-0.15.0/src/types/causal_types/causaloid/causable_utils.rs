/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalityError, Causaloid};
use deep_causality_core::{CausalEffect, EffectLog, PropagatingEffect, PropagatingProcess};
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
            // context_fn signature: fn(CausalEffect<I>, PS, Option<C>) -> PropagatingProcess<O, PS, C>
            // We invoke it with default state and the context.
            // The result is PropagatingProcess<O, PS, C>.
            // We need to convert it to PropagatingEffect<O>, preserving logs.

            let ev = CausalEffect::value(input);
            let process = context_fn(ev, PS::default(), Some(context.clone()));

            let (outcome, _state, _context, logs) = process.into_parts();
            let outcome = match outcome {
                Err(error) => Err(error),
                Ok(value) if value.is_none() => Err(CausalityError(
                    deep_causality_core::CausalityErrorEnum::Custom(
                        "execute_causal_logic: context_fn returned None value and no error".into(),
                    ),
                )),
                Ok(value) => Ok(value),
            };
            PropagatingEffect::new(outcome, (), None, logs)
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
    // Format must match expectation: "Causaloid {}: Incoming effect: {:?}"
    let ev = CausalEffect::value(input.clone());
    let mut logs = EffectLog::new();
    logs.add_entry(&format!("Causaloid {}: Incoming effect: {:?}", id, ev));
    PropagatingEffect::from_value_with_log(input, logs)
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
///   `(CausalEffect::value(input), state, context)` and its returned process is
///   returned to the caller intact (logs preserved, state preserved).
/// * Otherwise, if the stateless `causaloid.causal_fn` is set, it is invoked on
///   the value and the resulting `PropagatingEffect<O>` is lifted into a
///   `PropagatingProcess<O, S, C>` whose `state` and `context` channels are the
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
        let ev = CausalEffect::value(input);
        // Prefer the caller-supplied context; fall back to the causaloid's own
        // stored context only if the caller passed `None`. This mirrors the
        // existing context-discovery behaviour of `execute_causal_logic` while
        // honouring the caller's explicit choice when one is given.
        let effective_ctx = context.or_else(|| causaloid.context.clone());
        return context_fn(ev, state, effective_ctx);
    }

    if let Some(causal_fn) = &causaloid.causal_fn {
        let stateless: PropagatingEffect<O> = causal_fn(input);
        let (outcome, _unit_state, _no_context, logs) = stateless.into_parts();
        return PropagatingProcess::new(outcome, state, context, logs);
    }

    let err_msg = format!(
        "Causaloid {} is missing both causal_fn and context_causal_fn",
        causaloid.id
    );
    PropagatingProcess::new(
        Err(CausalityError(
            deep_causality_core::CausalityErrorEnum::Custom(err_msg),
        )),
        state,
        context,
        EffectLog::new(),
    )
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
    let ev = CausalEffect::value(input.clone());
    let mut logs = EffectLog::new();
    logs.add_entry(&format!("Causaloid {}: Incoming effect: {:?}", id, ev));
    PropagatingProcess::new(Ok(CausalEffect::value(input)), state, context, logs)
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
    let ev = CausalEffect::value(output.clone());
    let mut logs = EffectLog::new();
    logs.add_entry(&format!("Causaloid {}: Outgoing effect: {:?}", id, ev));
    PropagatingProcess::new(Ok(CausalEffect::value(output)), state, context, logs)
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
    // Format must match expectation: "Causaloid {}: Outgoing effect: {:?}"
    let ev = CausalEffect::value(output.clone());
    let mut logs = EffectLog::new();
    logs.add_entry(&format!("Causaloid {}: Outgoing effect: {:?}", id, ev));
    PropagatingEffect::from_value_with_log(output, logs)
}
