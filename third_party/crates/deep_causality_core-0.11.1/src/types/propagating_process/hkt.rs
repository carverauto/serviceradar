/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalEffect, EffectLog, PropagatingProcess};
use core::marker::PhantomData;
use deep_causality_haft::{
    Applicative, Functor, HKT, LogAppend, NoConstraint, Placeholder, Pure, Satisfies,
};

// Totality invariant (success channel): `fmap` and `apply` are total and never fabricate an error —
// `fmap` maps the value leaf through the `RelayTo` tree via the total `CausalEffect::map` (value maps,
// `None` passes through, command preserved); `apply` yields a value iff both operands carry one, else
// `none()`. Errors arise only from the `Err` channel. This is the same function the sibling witnesses
// (`PropagatingEffectWitness`, `CausalEffectPropagationProcessWitness`) and the inherent `fmap`
// compute — see `Core/Consistency.lean`.

pub struct PropagatingProcessWitness<S, C>(Placeholder, PhantomData<S>, PhantomData<C>);

impl<S, C> HKT for PropagatingProcessWitness<S, C> {
    type Constraint = NoConstraint;
    type Type<T> = PropagatingProcess<T, S, C>;
}

impl<S, C> Functor<Self> for PropagatingProcessWitness<S, C>
where
    S: Clone,
    C: Clone,
{
    fn fmap<A, B, Func>(m_a: <Self as HKT>::Type<A>, f: Func) -> <Self as HKT>::Type<B>
    where
        A: Satisfies<<Self as HKT>::Constraint>,
        B: Satisfies<<Self as HKT>::Constraint>,
        Func: FnOnce(A) -> B,
    {
        // Total value functor. `Err` short-circuits (left zero; state/context/logs preserved).
        // Otherwise the total `CausalEffect::map` maps the value leaf through the `RelayTo` tree — a
        // value maps, a `None` passes through, a command is preserved — never fabricating an error.
        let outcome = match m_a.outcome {
            Err(error) => Err(error),
            Ok(effect) => Ok(effect.map(f)),
        };

        PropagatingProcess::new(outcome, m_a.state, m_a.context, m_a.logs)
    }
}

impl<S, C> Pure<Self> for PropagatingProcessWitness<S, C>
where
    S: Clone + Default,
    C: Clone,
{
    fn pure<T>(value: T) -> <Self as HKT>::Type<T>
    where
        T: Satisfies<<Self as HKT>::Constraint>,
    {
        PropagatingProcess::new(
            Ok(CausalEffect::value(value)),
            S::default(),
            None,
            EffectLog::default(),
        )
    }
}

impl<S, C> Applicative<Self> for PropagatingProcessWitness<S, C>
where
    S: Clone + Default,
    C: Clone,
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

        // `Err` short-circuits (first error wins). On the success channel the applicative is total:
        // a value results iff both operands carry values, else absence (`none()`) — the lawful
        // `Maybe` applicative on the `Pure(Option V)` fragment. A value-less operand never fabricates
        // an error.
        let outcome = match (f_ab.outcome, f_a.outcome) {
            (Err(error), _) | (_, Err(error)) => Err(error),
            (Ok(func), Ok(arg)) => match (func.into_value(), arg.into_value()) {
                (Some(mut f), Some(a)) => Ok(CausalEffect::value(f(a))),
                _ => Ok(CausalEffect::none()),
            },
        };

        PropagatingProcess::new(outcome, f_ab.state, context, combined_logs)
    }
}

// NOTE: `PropagatingProcessWitness` deliberately does NOT implement the value-only `Monad` trait.
// Its `bind` continuation (`FnMut(A) -> M<B>`) cannot thread the Markovian `State` channel, so it
// could only freeze state. The correct, state-threading bind is the `CausalMonad` trait (and the
// inherent `bind` method on `CausalEffectPropagationProcess` / `PropagatingProcess`).
