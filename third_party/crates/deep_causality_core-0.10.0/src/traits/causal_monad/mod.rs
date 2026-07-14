/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # CausalMonad
//!
//! `CausalMonad` is the single, canonical monad of the DeepCausality effect system. It is a
//! **state-threading** effect monad over [`CausalEffectPropagationProcess`]: `bind`'s continuation
//! receives the carried value, the threaded state, and the optional context, and returns the next
//! process whose state and context are carried forward.
//!
//! There is exactly one `bind`. The stateful `PropagatingProcess<T, S, C>` threads real Markovian
//! state; the stateless `PropagatingEffect<T>` (`State = Context = ()`) threads the unit state
//! trivially. This replaces the earlier split between a value-only effect-system bind (which could
//! not thread state) and the state-threading implementation: the trait now *is* the contract, and
//! the value-only binds for stateful carriers have been removed.
//!
//! The same two operations are also exposed as inherent methods on the process, so call sites can
//! write `PropagatingEffect::pure(x)` and `effect.bind(...)` without importing this trait. The trait
//! exists so that generic code can bind against the contract, and so the API reflects the intent
//! (a state-threading monad) at the type level.

use crate::{CausalEffectPropagationProcess, CausalityError, EffectLog, EffectValue};

/// The state-threading effect monad for the propagating-effect family.
///
/// Implemented for `CausalEffectPropagationProcess<_, _, _, CausalityError, EffectLog>`, which
/// covers both `PropagatingEffect<T>` and `PropagatingProcess<T, S, C>`.
///
/// `bind` short-circuits on error (value becomes `EffectValue::None`, state/context/log preserved),
/// otherwise calls the continuation with the value, state, and context and keeps the state/context
/// of the process the continuation returns; logs are appended across the step.
pub trait CausalMonad: Sized {
    /// The carried value type.
    type Value;
    /// The threaded (Markovian) state type.
    type State;
    /// The read context type.
    type Context;

    /// Lift a value into the monad: value set, state defaulted, no error, empty log.
    fn pure(value: Self::Value) -> Self;

    /// State-threading monadic bind. See the trait documentation for the semantics.
    fn bind<NewValue, F>(
        self,
        f: F,
    ) -> CausalEffectPropagationProcess<
        NewValue,
        Self::State,
        Self::Context,
        CausalityError,
        EffectLog,
    >
    where
        F: FnOnce(
            EffectValue<Self::Value>,
            Self::State,
            Option<Self::Context>,
        ) -> CausalEffectPropagationProcess<
            NewValue,
            Self::State,
            Self::Context,
            CausalityError,
            EffectLog,
        >;
}

impl<Value, State, Context> CausalMonad
    for CausalEffectPropagationProcess<Value, State, Context, CausalityError, EffectLog>
where
    State: Default,
{
    type Value = Value;
    type State = State;
    type Context = Context;

    fn pure(value: Value) -> Self {
        Self {
            value: EffectValue::Value(value),
            state: State::default(),
            context: None,
            error: None,
            logs: EffectLog::new(),
        }
    }

    fn bind<NewValue, F>(
        self,
        f: F,
    ) -> CausalEffectPropagationProcess<NewValue, State, Context, CausalityError, EffectLog>
    where
        F: FnOnce(
            EffectValue<Value>,
            State,
            Option<Context>,
        ) -> CausalEffectPropagationProcess<
            NewValue,
            State,
            Context,
            CausalityError,
            EffectLog,
        >,
    {
        // The state-threading logic lives on the inherent `bind`. Inherent methods take priority in
        // method resolution, so this call resolves to the inherent method and does not recurse.
        self.bind(f)
    }
}
