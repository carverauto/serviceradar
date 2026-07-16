/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalEffect, CausalEffectPropagationProcess};
use core::marker::PhantomData;
use deep_causality_haft::{
    Applicative, Functor, HKT, HKT5, LogAppend, NoConstraint, Placeholder, Pure, Satisfies,
};

pub struct CausalEffectPropagationProcessWitness<S, C, E, L>(
    Placeholder,
    PhantomData<S>,
    PhantomData<C>,
    PhantomData<E>,
    PhantomData<L>,
);

// Impl for arity-5 fixed-effect HKT
impl<S, C, E, L> HKT5<S, C, E, L> for CausalEffectPropagationProcessWitness<S, C, E, L> {
    type Type<Value> = CausalEffectPropagationProcess<Value, S, C, E, L>;
}

// Impl for arity-1 HKT, required by Functor/Monad bounds on Effect5
impl<S, C, E, L> HKT for CausalEffectPropagationProcessWitness<S, C, E, L> {
    type Constraint = NoConstraint;
    type Type<Value> = CausalEffectPropagationProcess<Value, S, C, E, L>;
}

impl<S, C, E, L> Functor<Self> for CausalEffectPropagationProcessWitness<S, C, E, L>
where
    S: Clone,
    C: Clone,
    E: Clone,
    L: Clone,
{
    fn fmap<A, B, Func>(m_a: <Self as HKT>::Type<A>, f: Func) -> <Self as HKT>::Type<B>
    where
        A: Satisfies<<Self as HKT>::Constraint>,
        B: Satisfies<<Self as HKT>::Constraint>,
        Func: FnOnce(A) -> B,
    {
        // Error short-circuits: `f` is not invoked; the error propagates (left zero). Otherwise the
        // total `CausalEffect::map` handles value/none/command uniformly — a value maps its leaf, a
        // `None` passes through, and a command is preserved (its sub-program leaf mapped). No panic,
        // no manufactured error. This matches the inherent `fmap` exactly (see `Core/Consistency.lean`).
        let outcome = match m_a.outcome {
            Err(error) => Err(error),
            Ok(effect) => Ok(effect.map(f)),
        };
        CausalEffectPropagationProcess {
            outcome,
            state: m_a.state,
            context: m_a.context,
            logs: m_a.logs,
        }
    }
}

impl<S, C, E, L> Pure<Self> for CausalEffectPropagationProcessWitness<S, C, E, L>
where
    S: Clone + Default,
    C: Clone,
    E: Clone,
    L: LogAppend + Clone + Default,
{
    fn pure<T>(value: T) -> <Self as HKT>::Type<T>
    where
        T: Satisfies<<Self as HKT>::Constraint>,
    {
        CausalEffectPropagationProcess {
            outcome: Ok(CausalEffect::value(value)),
            state: S::default(),
            context: None,
            logs: L::default(),
        }
    }
}

impl<S, C, E, L> Applicative<Self> for CausalEffectPropagationProcessWitness<S, C, E, L>
where
    S: Clone + Default,
    C: Clone,
    E: Clone,
    L: LogAppend + Clone + Default,
{
    fn apply<A, B, Func>(
        f_ab: <Self as HKT>::Type<Func>,
        mut f_a: <Self as HKT>::Type<A>,
    ) -> <Self as HKT>::Type<B>
    where
        A: Satisfies<<Self as HKT>::Constraint> + Clone,
        B: Satisfies<<Self as HKT>::Constraint>,
        Func: Satisfies<<Self as HKT>::Constraint> + FnMut(A) -> B,
    {
        let mut combined_logs = f_ab.logs;
        combined_logs.append(&mut f_a.logs);
        let context = f_ab.context.or(f_a.context);

        // Error short-circuits: the function is not invoked; the first error propagates (left zero).
        // If either side lacks a value (a `None` or command effect), the result is `None` — no panic.
        let outcome = match (f_ab.outcome, f_a.outcome) {
            (Err(error), _) | (_, Err(error)) => Err(error),
            (Ok(func), Ok(arg)) => match (func.into_value(), arg.into_value()) {
                (Some(mut func), Some(arg)) => Ok(CausalEffect::value(func(arg))),
                _ => Ok(CausalEffect::none()),
            },
        };

        CausalEffectPropagationProcess {
            outcome,
            state: f_ab.state,
            context,
            logs: combined_logs,
        }
    }
}

// NOTE: `CausalEffectPropagationProcessWitness` deliberately does NOT implement the value-only
// `Monad` trait. Its `bind` continuation (`FnMut(A) -> M<B>`) cannot thread the Markovian `State`
// channel, so it could only freeze state. The correct, state-threading bind is the `CausalMonad`
// trait (and the inherent `bind` method on `CausalEffectPropagationProcess`).
