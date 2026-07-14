/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalMonad, CausalityError, CausalityErrorEnum, EffectLog, EffectValue};
use core::fmt::Debug;
use deep_causality_haft::LogAppend;

mod alternatable_context;
mod alternatable_state;
mod alternatable_value;
mod display;
mod explain;
mod getters;
pub mod hkt;
mod intervenable;
mod predicates;

/// The fundamental unit of causal computation in DeepCausality.
///
/// `CausalEffectPropagationProcess` encapsulates the state of a computation moving through a causal
/// graph. It unifies value propagation, state management, context awareness, error handling, and
/// comprehensive logging into a single, monadic structure.
///
/// # Concepts
///
/// *   **Value**: The primary data being transformed (e.g., a signal, a decision).
/// *   **State**: Persistent data that evolves as the process moves through the graph (Markovian state).
/// *   **Context**: Read-only configuration or environment data available to all steps.
/// *   **Error**: A failure state that short-circuits further computation but preserves logs.
/// *   **Logs**: An append-only history of every step, essential for auditability and explainability.
///
/// # Rationale
///
/// In complex causal reasoning, it is not enough to just know the final result. We must know *how*
/// that result was reached, what invalid states were encountered, and what context was active.
/// This struct implements the [Monad](https://en.wikipedia.org/wiki/Monad_(functional_programming)) pattern
/// to handle these concerns automatically, allowing users to focus on the domain logic ("Business Logic")
/// rather than plumbing (error checking, logging).
#[derive(Debug, PartialEq, Clone)]
pub struct CausalEffectPropagationProcess<Value, State, Context, Error, Log> {
    /// The current value of the computation.
    pub value: EffectValue<Value>,
    /// The current state of the process (e.g., accumulated risk, counters).
    pub state: State,
    /// The optional execution context (e.g., global config, reference data).
    pub context: Option<Context>,
    /// The current error state. If `Some`, new `bind` operations will skip execution.
    pub error: Option<Error>,
    /// The audit log containing the history of operations.
    pub logs: Log,
}

impl<Value, State, Context, Error, Log>
    CausalEffectPropagationProcess<Value, State, Context, Error, Log>
where
    Log: LogAppend + Default,
    Error: Clone,
{
    /// Chains a stateful, context-aware computation.
    ///
    /// This is the primary method for building Markovian process chains, as the
    /// function `f` receives the value, state, and context from the previous step.
    pub fn bind<F, NewValue>(
        self,
        f: F,
    ) -> CausalEffectPropagationProcess<NewValue, State, Context, Error, Log>
    where
        F: FnOnce(
            EffectValue<Value>,
            State,
            Option<Context>,
        ) -> CausalEffectPropagationProcess<NewValue, State, Context, Error, Log>,
    {
        if let Some(error) = self.error {
            return CausalEffectPropagationProcess {
                value: EffectValue::default(),
                state: self.state,
                context: self.context,
                error: Some(error),
                logs: self.logs,
            };
        }

        let mut next_process = f(self.value, self.state, self.context);

        let mut combined_logs = self.logs;
        combined_logs.append(&mut next_process.logs);
        next_process.logs = combined_logs;

        next_process
    }
}

impl<Value, State, Context, Error, Log>
    CausalEffectPropagationProcess<Value, State, Context, Error, Log>
where
    Log: Clone,
    Error: Clone,
{
    /// Lifts a stateless effect into a stateful process by providing an initial state and context.
    ///
    /// This is the primary entry point for starting a stateful computation chain from a
    /// simple, pre-existing effect.
    ///
    /// # Arguments
    /// * `effect`: The stateless `PropagatingEffect` (where State and Context are `()`).
    /// * `initial_state`: The starting state for the new process.
    /// * `initial_context`: The optional starting context for the new process.
    ///
    /// # Returns
    /// A new `CausalEffectPropagationProcess` ready for stateful operations.
    pub fn with_state(
        effect: CausalEffectPropagationProcess<Value, (), (), Error, Log>,
        initial_state: State,
        initial_context: Option<Context>,
    ) -> Self {
        Self {
            value: effect.value,
            state: initial_state,
            context: initial_context,
            error: effect.error,
            logs: effect.logs,
        }
    }
}

// These constructors are generic over State and Context and can be used by any alias.
impl<Value, State, Context>
    CausalEffectPropagationProcess<Value, State, Context, CausalityError, EffectLog>
where
    Value: Default + Clone + Debug,
    State: Default + Clone + Debug,
    Context: Clone + Debug,
{
    /// Creates a new process that explicitly contains an error.
    /// The state is set to default.
    pub fn from_error(err: CausalityError) -> Self {
        Self {
            value: EffectValue::None,
            state: State::default(),
            context: None,
            error: Some(err),
            logs: EffectLog::new(),
        }
    }

    /// Creates a new process with `EffectValue::None`, default state, and no error.
    pub fn none() -> Self {
        Self {
            value: EffectValue::None,
            state: State::default(),
            context: None,
            error: None,
            logs: EffectLog::new(),
        }
    }

    /// Lifts a pure value into a process with a default state.
    pub fn pure(value: Value) -> Self {
        <Self as CausalMonad>::pure(value)
    }

    /// Maps the carried value with `f`, preserving state, context, and logs.
    ///
    /// This is the fluent `Functor` operation on the carrier, the value-only counterpart to
    /// [`bind`](Self::bind). It never panics. An error carrier short-circuits: the error and logs
    /// are preserved and the value becomes `None`. A `None` or `ContextualLink` carrier passes
    /// through unchanged. The dispatch variants `RelayTo` and `Map` embed a `PropagatingEffect`
    /// whose value type cannot be retyped by a value-level map, so `fmap` over them surfaces a
    /// `ValueNotAvailable` error rather than silently dropping the routing command; reach for
    /// [`bind`](Self::bind) when you need to act on those variants.
    pub fn fmap<NewValue, F>(
        self,
        f: F,
    ) -> CausalEffectPropagationProcess<NewValue, State, Context, CausalityError, EffectLog>
    where
        F: FnOnce(Value) -> NewValue,
    {
        // Error short-circuits: preserve state, context, the error, and the accumulated log.
        if self.error.is_some() {
            return CausalEffectPropagationProcess {
                value: EffectValue::None,
                state: self.state,
                context: self.context,
                error: self.error,
                logs: self.logs,
            };
        }

        let (value, error) = match self.value {
            EffectValue::Value(v) => (EffectValue::Value(f(v)), None),
            EffectValue::None => (EffectValue::None, None),
            EffectValue::ContextualLink(a, b) => (EffectValue::ContextualLink(a, b), None),
            // RelayTo / Map carry a `PropagatingEffect<Value>` that a value-level `fmap` cannot
            // retype to `NewValue`. Surface this instead of dropping the dispatch command.
            _ => (
                EffectValue::None,
                Some(CausalityError::new(CausalityErrorEnum::ValueNotAvailable)),
            ),
        };

        CausalEffectPropagationProcess {
            value,
            state: self.state,
            context: self.context,
            error,
            logs: self.logs,
        }
    }

    /// Creates a new process from a given `EffectValue`.
    /// The state is set to default.
    pub fn from_effect_value(effect_value: EffectValue<Value>) -> Self {
        Self {
            value: effect_value,
            state: State::default(),
            context: None,
            error: None,
            logs: EffectLog::new(),
        }
    }

    pub fn from_value(value: Value) -> Self {
        Self {
            value: EffectValue::Value(value),
            state: State::default(),
            context: None,
            error: None,
            logs: EffectLog::new(),
        }
    }

    /// Creates a new process from a given `EffectValue` and `EffectLog`.
    /// The state is set to default.
    pub fn from_effect_value_with_log(value: EffectValue<Value>, logs: EffectLog) -> Self {
        Self {
            value,
            state: State::default(),
            context: None,
            error: None,
            logs,
        }
    }

    pub fn from_value_with_log(value: Value, logs: EffectLog) -> Self {
        Self {
            value: EffectValue::Value(value),
            state: State::default(),
            context: None,
            error: None,
            logs,
        }
    }
}

impl<Value, State, Context, Log>
    CausalEffectPropagationProcess<Value, State, Context, CausalityError, Log>
where
    Log: LogAppend + Default,
{
    /// Chains a computation while automatically unwrapping the inner `EffectValue`.
    ///
    /// If the `EffectValue` is `None`, this method short-circuits with a `CausalityError`
    /// containing the provided `err_msg`. This simplifies the common pattern of:
    /// `bind -> match effect_value { Some(v) => f(v), None => Error }`
    pub fn bind_or_error<F, NewValue>(
        self,
        f: F,
        err_msg: &str,
    ) -> CausalEffectPropagationProcess<NewValue, State, Context, CausalityError, Log>
    where
        F: FnOnce(
            Value,
            State,
            Option<Context>,
        )
            -> CausalEffectPropagationProcess<NewValue, State, Context, CausalityError, Log>,
    {
        if let Some(error) = self.error {
            return CausalEffectPropagationProcess {
                value: EffectValue::default(),
                state: self.state,
                context: self.context,
                error: Some(error),
                logs: self.logs,
            };
        }

        match self.value.into_value() {
            Some(v) => {
                let mut next_process = f(v, self.state, self.context);
                let mut combined_logs = self.logs;
                combined_logs.append(&mut next_process.logs);
                next_process.logs = combined_logs;
                next_process
            }
            None => CausalEffectPropagationProcess {
                value: EffectValue::default(),
                state: self.state,
                context: self.context,
                error: Some(CausalityError(crate::CausalityErrorEnum::Custom(
                    err_msg.into(),
                ))),
                logs: self.logs,
            },
        }
    }
}
