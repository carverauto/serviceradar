/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CoMonad, HKT, Satisfies};

/// Alias trait for `CoMonad` providing more intuitive method names.
///
/// - `observe` → `extract`: Gets the value at the current focus.
/// - `propagate` → `extend`: Extends the context by applying a function.
pub trait AliasCoMonad<F: HKT>: CoMonad<F> {
    /// Alias for `extract`. Gets the value at the current focus.
    #[inline]
    fn observe<A>(fa: &F::Type<A>) -> A
    where
        A: Satisfies<F::Constraint> + Clone,
    {
        Self::extract(fa)
    }

    /// Alias for `extend`. Propagates a computation across the context.
    #[inline]
    fn propagate<A, B, Func>(fa: &F::Type<A>, f: Func) -> F::Type<B>
    where
        A: Satisfies<F::Constraint> + Clone,
        B: Satisfies<F::Constraint>,
        Func: FnMut(&F::Type<A>) -> B,
    {
        Self::extend(fa, f)
    }
}

// Blanket implementation
impl<T, F> AliasCoMonad<F> for T
where
    T: CoMonad<F>,
    F: HKT,
{
}
