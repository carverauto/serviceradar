/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalityError, CausalityErrorEnum, EffectLog, EffectValue, PropagatingProcess};
use core::marker::PhantomData;
use deep_causality_haft::{
    Applicative, Functor, HKT, LogAppend, NoConstraint, Placeholder, Pure, Satisfies,
};

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
        if m_a.error.is_some() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: m_a.state,
                context: m_a.context,
                error: m_a.error,
                logs: m_a.logs,
            };
        }

        match m_a.value.into_value() {
            Some(a) => PropagatingProcess {
                value: EffectValue::Value(f(a)),
                state: m_a.state,
                context: m_a.context,
                error: m_a.error,
                logs: m_a.logs,
            },
            None => PropagatingProcess {
                value: EffectValue::None,
                state: m_a.state,
                context: m_a.context,
                error: Some(CausalityError::new(CausalityErrorEnum::InternalLogicError)),
                logs: m_a.logs,
            },
        }
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
        PropagatingProcess {
            value: EffectValue::Value(value),
            state: S::default(),
            context: None,
            error: None,
            logs: EffectLog::default(),
        }
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

        let error = f_ab.error.or(f_a.error);
        if error.is_some() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: f_ab.state,
                context: f_ab.context.or(f_a.context),
                error,
                logs: combined_logs,
            };
        }

        match (f_ab.value.into_value(), f_a.value.into_value()) {
            (Some(mut f), Some(a)) => PropagatingProcess {
                value: EffectValue::Value(f(a)),
                state: f_ab.state,
                context: f_ab.context.or(f_a.context),
                error,
                logs: combined_logs,
            },
            _ => PropagatingProcess {
                value: EffectValue::None,
                state: f_ab.state,
                context: f_ab.context.or(f_a.context),
                error: Some(CausalityError::new(CausalityErrorEnum::InternalLogicError)),
                logs: combined_logs,
            },
        }
    }
}

// NOTE: `PropagatingProcessWitness` deliberately does NOT implement the value-only `Monad` trait.
// Its `bind` continuation (`FnMut(A) -> M<B>`) cannot thread the Markovian `State` channel, so it
// could only freeze state. The correct, state-threading bind is the `CausalMonad` trait (and the
// inherent `bind` method on `CausalEffectPropagationProcess` / `PropagatingProcess`).
