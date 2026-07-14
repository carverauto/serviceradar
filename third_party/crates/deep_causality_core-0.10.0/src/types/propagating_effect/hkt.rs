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

use crate::{
    CausalEffectPropagationProcess, CausalityError, CausalityErrorEnum, EffectLog, EffectValue,
};
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
        if m_a.is_err() {
            return CausalEffectPropagationProcess {
                value: EffectValue::None,
                state: (),
                context: None,
                error: m_a.error,
                logs: m_a.logs,
            };
        }

        match m_a.value.into_value() {
            Some(a) => CausalEffectPropagationProcess {
                value: EffectValue::Value(f(a)),
                state: (),
                context: None,
                error: None,
                logs: m_a.logs,
            },
            None => CausalEffectPropagationProcess {
                value: EffectValue::None,
                state: (),
                context: None,
                error: Some(CausalityError::new(CausalityErrorEnum::InternalLogicError)),
                logs: m_a.logs,
            },
        }
    }
}

impl Pure<Self> for PropagatingEffectWitness<CausalityError, EffectLog> {
    fn pure<T>(value: T) -> <Self as HKT>::Type<T>
    where
        T: Satisfies<<Self as HKT>::Constraint>,
    {
        CausalEffectPropagationProcess {
            value: EffectValue::Value(value),
            state: (),
            context: None,
            error: None,
            logs: EffectLog::new(),
        }
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

        if f_ab.error.is_some() || f_a.error.is_some() {
            return CausalEffectPropagationProcess {
                value: EffectValue::None,
                state: (),
                context: None,
                error: f_ab.error.or(f_a.error),
                logs: combined_logs,
            };
        }

        match (f_ab.value.into_value(), f_a.value.into_value()) {
            (Some(mut f), Some(a)) => CausalEffectPropagationProcess {
                value: EffectValue::Value(f(a)),
                state: (),
                context: None,
                error: None,
                logs: combined_logs,
            },
            _ => CausalEffectPropagationProcess {
                value: EffectValue::None,
                state: (),
                context: None,
                error: Some(CausalityError::new(CausalityErrorEnum::InternalLogicError)),
                logs: combined_logs,
            },
        }
    }
}

impl Monad<Self> for PropagatingEffectWitness<CausalityError, EffectLog> {
    fn bind<A, B, Func>(m_a: <Self as HKT>::Type<A>, f: Func) -> <Self as HKT>::Type<B>
    where
        A: Satisfies<<Self as HKT>::Constraint>,
        B: Satisfies<<Self as HKT>::Constraint>,
        Func: FnOnce(A) -> <Self as HKT>::Type<B>,
    {
        if m_a.error.is_some() {
            return CausalEffectPropagationProcess {
                value: EffectValue::None,
                state: (),
                context: None,
                error: m_a.error,
                logs: m_a.logs,
            };
        }

        match m_a.value.into_value() {
            Some(a) => {
                let mut next_effect = f(a);
                let mut combined_logs = m_a.logs;
                combined_logs.append(&mut next_effect.logs);
                next_effect.logs = combined_logs;
                next_effect
            }
            None => CausalEffectPropagationProcess {
                value: EffectValue::None,
                state: (),
                context: None,
                error: Some(CausalityError::new(CausalityErrorEnum::InternalLogicError)),
                logs: m_a.logs,
            },
        }
    }
}
