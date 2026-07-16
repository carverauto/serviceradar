/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalEffect, CausalMonad, CausalityError, EffectLog};
use core::fmt::Debug;
use deep_causality_haft::LogAppend;

mod alternatable_context;
mod alternatable_state;
mod alternatable_value;
mod display;
mod explain;
mod getters;
pub mod hkt;
mod predicates;

/// The fundamental unit of causal computation in DeepCausality.
///
/// `CausalEffectPropagationProcess` encapsulates the state of a computation moving through a causal
/// graph. It unifies value propagation, state management, context awareness, error handling, and
/// comprehensive logging into a single, monadic structure.
///
/// # Concepts
///
/// *   **Outcome**: The value/control-XOR-error channel — `Result<CausalEffect<Value>, Error>`,
///     the `Except E (Free CausalCommand (Maybe T))` encoding. On the success side a process
///     carries a `CausalEffect<Value>` — a value, `None`, or a control command (`RelayTo`); on
///     the failure side it carries an error, never both: the W-invariant
///     (`error present ⇒ no value`) holds **by construction**, not by discipline.
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
///
/// Because value and error live in ONE channel, the three monad laws (left identity, right
/// identity, associativity) hold **unconditionally** — including on errored carriers — and the
/// error short-circuit is a left zero (`bind(raise e, f) = raise e`, `f` never runs). This is
/// precondition P2 of the Causal Algebra program
/// (`openspec/notes/causal-algebra/Formalization.md` §2), machine-checked in
/// `lean/DeepCausalityFormal/Core/CausalMonad.lean`.
///
/// All fields are private; construct via [`new`](Self::new) (total — every representable state
/// is valid) or the named constructors, decompose via [`into_parts`](Self::into_parts), and read
/// via the getters in `getters.rs`.
#[derive(Debug, PartialEq, Clone)]
pub struct CausalEffectPropagationProcess<Value, State, Context, Error, Log> {
    /// The value-XOR-error channel: an effect value, or the error that ended the computation.
    pub(crate) outcome: Result<CausalEffect<Value>, Error>,
    /// The current state of the process (e.g., accumulated risk, counters).
    pub(crate) state: State,
    /// The optional execution context (e.g., global config, reference data).
    pub(crate) context: Option<Context>,
    /// The audit log containing the history of operations.
    pub(crate) logs: Log,
}

impl<Value, State, Context, Error, Log>
    CausalEffectPropagationProcess<Value, State, Context, Error, Log>
{
    /// Total constructor over the single-channel representation.
    ///
    /// With value-XOR-error encoded as one `Result`, every combination of arguments is a
    /// valid process — there is nothing to validate and no way to construct the formerly
    /// representable invalid state (value AND error).
    pub const fn new(
        outcome: Result<CausalEffect<Value>, Error>,
        state: State,
        context: Option<Context>,
        logs: Log,
    ) -> Self {
        Self {
            outcome,
            state,
            context,
            logs,
        }
    }

    /// Decomposes the process into its channels: `(outcome, state, context, logs)`.
    ///
    /// The inverse of [`new`](Self::new); the by-value counterpart to the getters.
    pub fn into_parts(
        self,
    ) -> (
        Result<CausalEffect<Value>, Error>,
        State,
        Option<Context>,
        Log,
    ) {
        (self.outcome, self.state, self.context, self.logs)
    }

    /// Consumes the process and returns the carried scalar, if any.
    ///
    /// This is the terminal "give me the result value" accessor: it yields `Some(v)` only when
    /// the process carries a value effect, and `None` for an errored process, a `None` effect, or a
    /// command. It is the by-value counterpart to [`value`](Self::value), and mirrors
    /// [`CausalEffect::into_value`](crate::CausalEffect::into_value). Use it at the end of a chain
    /// when you want the plain value out for display or comparison rather than a reference.
    pub fn into_value(self) -> Option<Value> {
        self.outcome.ok().and_then(CausalEffect::into_value)
    }
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
    ///
    /// Error short-circuits as a left zero: on an errored process, `f` is NOT invoked and the
    /// process is returned reassembled verbatim (error, state, context, and logs preserved),
    /// which is what makes right identity `bind(m, pure) = m` hold unconditionally.
    pub fn bind<F, NewValue>(
        self,
        f: F,
    ) -> CausalEffectPropagationProcess<NewValue, State, Context, Error, Log>
    where
        F: FnOnce(
            CausalEffect<Value>,
            State,
            Option<Context>,
        ) -> CausalEffectPropagationProcess<NewValue, State, Context, Error, Log>,
    {
        match self.outcome {
            Err(error) => CausalEffectPropagationProcess {
                outcome: Err(error),
                state: self.state,
                context: self.context,
                logs: self.logs,
            },
            Ok(effect) => {
                let mut next_process = f(effect, self.state, self.context);

                let mut combined_logs = self.logs;
                combined_logs.append(&mut next_process.logs);
                next_process.logs = combined_logs;

                next_process
            }
        }
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
            outcome: effect.outcome,
            state: initial_state,
            context: initial_context,
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
            outcome: Err(err),
            state: State::default(),
            context: None,
            logs: EffectLog::new(),
        }
    }

    /// Creates a new process carrying the `None` effect (absence of evidence), default state, no error.
    pub fn none() -> Self {
        Self {
            outcome: Ok(CausalEffect::none()),
            state: State::default(),
            context: None,
            logs: EffectLog::new(),
        }
    }

    /// Lifts a pure value into a process with a default state.
    pub fn pure(value: Value) -> Self {
        <Self as CausalMonad>::pure(value)
    }

    /// Maps the carried value with `f`, preserving state, context, and logs.
    ///
    /// The fluent `Functor` operation on the carrier. It is **total**: it delegates to the total
    /// [`CausalEffect::map`], so a value maps its leaf (`Some(v) → Some(f(v))`), a `None` passes
    /// through, and a **command is preserved** — its sub-program's value leaf is mapped through the
    /// `RelayTo` tree, so the command survives with its target intact. It never panics and never
    /// manufactures an error; an errored carrier short-circuits (`f` not invoked, error + logs
    /// preserved).
    ///
    /// This is the functor, not the monad: [`bind`](Self::bind) is a value-level Kleisli step whose
    /// continuation needs a *value*, so — unlike `fmap` — it cannot run under a command and the
    /// reasoning engine folds commands (via [`CausalEffect::fold`]) before `bind` sees them. Hence
    /// `fmap f` and `bind(pure ∘ f)` coincide on the value fragment but diverge on a command (`fmap`
    /// preserves it; `bind` defers it).
    pub fn fmap<NewValue, F>(
        self,
        f: F,
    ) -> CausalEffectPropagationProcess<NewValue, State, Context, CausalityError, EffectLog>
    where
        F: FnOnce(Value) -> NewValue,
    {
        let outcome = match self.outcome {
            // Error short-circuits: `f` is not invoked; the error is preserved.
            Err(error) => Err(error),
            // Total functor: value/none/command are all handled by `CausalEffect::map`.
            Ok(effect) => Ok(effect.map(f)),
        };

        CausalEffectPropagationProcess {
            outcome,
            state: self.state,
            context: self.context,
            logs: self.logs,
        }
    }

    /// Creates a new process from a given [`CausalEffect`]. The state is set to default.
    pub fn from_effect(effect: CausalEffect<Value>) -> Self {
        Self {
            outcome: Ok(effect),
            state: State::default(),
            context: None,
            logs: EffectLog::new(),
        }
    }

    pub fn from_value(value: Value) -> Self {
        Self {
            outcome: Ok(CausalEffect::value(value)),
            state: State::default(),
            context: None,
            logs: EffectLog::new(),
        }
    }

    /// Creates a new process from a given [`CausalEffect`] and `EffectLog`. State set to default.
    pub fn from_effect_with_log(effect: CausalEffect<Value>, logs: EffectLog) -> Self {
        Self {
            outcome: Ok(effect),
            state: State::default(),
            context: None,
            logs,
        }
    }

    pub fn from_value_with_log(value: Value, logs: EffectLog) -> Self {
        Self {
            outcome: Ok(CausalEffect::value(value)),
            state: State::default(),
            context: None,
            logs,
        }
    }

    /// Creates a control-carrier process: a `RelayTo(target, input)` adaptive-reasoning jump.
    /// Default state, no context, empty log.
    pub fn relay_to(target: usize, input: CausalEffect<Value>) -> Self {
        Self {
            outcome: Ok(CausalEffect::relay_to(target, input)),
            state: State::default(),
            context: None,
            logs: EffectLog::new(),
        }
    }
}

impl<Value, State, Context, Log>
    CausalEffectPropagationProcess<Value, State, Context, CausalityError, Log>
where
    Log: LogAppend + Default,
{
    /// Chains a computation while automatically unwrapping the inner value effect.
    ///
    /// If the effect is `None`, this method short-circuits with a `CausalityError`
    /// containing the provided `err_msg`. This simplifies the common pattern of:
    /// `bind -> match effect_value { Some(v) => f(v), None => Error }`
    ///
    /// On an errored process, the continuation is NOT invoked (left zero).
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
        match self.outcome {
            Err(error) => CausalEffectPropagationProcess {
                outcome: Err(error),
                state: self.state,
                context: self.context,
                logs: self.logs,
            },
            Ok(effect_value) => match effect_value.into_value() {
                Some(v) => {
                    let mut next_process = f(v, self.state, self.context);
                    let mut combined_logs = self.logs;
                    combined_logs.append(&mut next_process.logs);
                    next_process.logs = combined_logs;
                    next_process
                }
                None => CausalEffectPropagationProcess {
                    outcome: Err(CausalityError(crate::CausalityErrorEnum::Custom(
                        err_msg.into(),
                    ))),
                    state: self.state,
                    context: self.context,
                    logs: self.logs,
                },
            },
        }
    }
}
