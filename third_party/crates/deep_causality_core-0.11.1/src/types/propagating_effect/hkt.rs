/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module provides Higher-Kinded Type (HKT) implementations for `PropagatingEffect`.
//!
//! By implementing `HKT`, `Functor`, `Applicative`, and `Monad` traits from the `deep_causality_haft` crate,
//! this module enables `PropagatingEffect` to be used in a functional programming style.
//! This allows for chaining operations, transforming values, and handling errors and logs
//! in a structured and composable manner, similar to how monads and functors work in other languages.
//!
//! ## Totality invariant (success channel)
//!
//! The law-bearing HKT instances below — `Functor::fmap`, `Applicative::apply`, `Monad::bind` — are
//! **total** on the success channel and never fabricate an error: `fmap` maps the value leaf through
//! the `RelayTo` tree via the total [`CausalEffect::map`] (a value maps, a `None` passes through, a
//! command is preserved); `apply` yields a value iff both operands carry one, else `none()`; `bind`
//! runs the continuation on a value and short-circuits absence lawfully (`None >>= f = None`).
//! Errors arise only from the `Err` channel (`Err` short-circuits, left zero). `fmap` and `apply`
//! compute the same total function as the sibling witnesses
//! ([`PropagatingProcessWitness`](crate::PropagatingProcessWitness),
//! [`CausalEffectPropagationProcessWitness`](crate::CausalEffectPropagationProcessWitness)) and, for
//! `fmap`, the inherent [`CausalEffectPropagationProcess::fmap`]; `bind` is unique to this witness
//! (the sibling witnesses omit the value-only `Monad` — see their note) and is the lawful `Maybe`
//! monad on the `Pure(Option V)` fragment. See `Core/Consistency.lean`.
//! (The deliberately *strict* fluent steps `CausalFlow::and_then` / `bind_or_error`, which surface a
//! missing value as an error, are a separate convenience layer, not these law-bearing instances.)

use crate::{CausalEffect, CausalEffectPropagationProcess, CausalityError, EffectLog};
use core::marker::PhantomData;
use deep_causality_haft::{
    Applicative, Functor, HKT, HKT3, LogAppend, Monad, NoConstraint, Placeholder, Pure, Satisfies,
};

pub struct PropagatingEffectWitness<E, L>(Placeholder, PhantomData<E>, PhantomData<L>);

impl<E, L> HKT for PropagatingEffectWitness<E, L> {
    type Constraint = NoConstraint;
    type Type<T> = CausalEffectPropagationProcess<T, (), (), E, L>;
}

impl<E, L> HKT3<E, L> for PropagatingEffectWitness<E, L> {
    type Type<T> = CausalEffectPropagationProcess<T, (), (), E, L>;
}

impl Functor<Self> for PropagatingEffectWitness<CausalityError, EffectLog> {
    fn fmap<A, B, Func>(m_a: <Self as HKT>::Type<A>, f: Func) -> <Self as HKT>::Type<B>
    where
        A: Satisfies<<Self as HKT>::Constraint>,
        B: Satisfies<<Self as HKT>::Constraint>,
        Func: FnOnce(A) -> B,
    {
        // Total value functor. `Err` short-circuits (left zero; logs preserved). Otherwise the total
        // `CausalEffect::map` maps the value leaf through the `RelayTo` tree — a value maps, a `None`
        // passes through, a command is preserved — never fabricating an error on the success channel.
        let outcome = match m_a.outcome {
            Err(error) => Err(error),
            Ok(effect) => Ok(effect.map(f)),
        };

        CausalEffectPropagationProcess::new(outcome, (), None, m_a.logs)
    }
}

impl Pure<Self> for PropagatingEffectWitness<CausalityError, EffectLog> {
    fn pure<T>(value: T) -> <Self as HKT>::Type<T>
    where
        T: Satisfies<<Self as HKT>::Constraint>,
    {
        CausalEffectPropagationProcess::new(
            Ok(CausalEffect::value(value)),
            (),
            None,
            EffectLog::new(),
        )
    }
}

impl Applicative<Self> for PropagatingEffectWitness<CausalityError, EffectLog> {
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

        // `Err` short-circuits (first error wins). On the success channel the applicative is total:
        // a value results iff both operands carry values, else absence (`none()`) — the lawful
        // `Maybe` applicative on the `Pure(Option V)` fragment. A value-less operand (a `None`, or a
        // command the engine folds first) short-circuits to absence and never fabricates an error.
        let outcome = match (f_ab.outcome, f_a.outcome) {
            (Err(error), _) | (_, Err(error)) => Err(error),
            (Ok(func), Ok(arg)) => match (func.into_value(), arg.into_value()) {
                (Some(mut f), Some(a)) => Ok(CausalEffect::value(f(a))),
                _ => Ok(CausalEffect::none()),
            },
        };

        CausalEffectPropagationProcess::new(outcome, (), None, combined_logs)
    }
}

impl Monad<Self> for PropagatingEffectWitness<CausalityError, EffectLog> {
    fn bind<A, B, Func>(m_a: <Self as HKT>::Type<A>, f: Func) -> <Self as HKT>::Type<B>
    where
        A: Satisfies<<Self as HKT>::Constraint>,
        B: Satisfies<<Self as HKT>::Constraint>,
        Func: FnOnce(A) -> <Self as HKT>::Type<B>,
    {
        match m_a.outcome {
            // Error short-circuits: the continuation is not invoked (left zero).
            Err(error) => CausalEffectPropagationProcess::new(Err(error), (), None, m_a.logs),
            Ok(effect) => match effect.into_value() {
                Some(a) => {
                    let mut next_effect = f(a);
                    let mut combined_logs = m_a.logs;
                    combined_logs.append(&mut next_effect.logs);
                    next_effect.logs = combined_logs;
                    next_effect
                }
                // Absence short-circuits lawfully — `None >>= f = None` (right identity), so no error
                // is fabricated. A command is the free monad's `Suspend` layer, interpreted by
                // `CausalEffect::fold` in the reasoning engine before any value-level `bind`; reaching
                // here (out of the value monad's domain) it short-circuits to absence likewise.
                None => CausalEffectPropagationProcess::new(
                    Ok(CausalEffect::none()),
                    (),
                    None,
                    m_a.logs,
                ),
            },
        }
    }
}
