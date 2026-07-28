/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT, Monad, Satisfies};

/// Alias trait for `Monad` providing more intuitive method names.
///
/// - `chain` → `bind`: Chains a computation, flattening nested containers.
/// - `flatten` → `join`: Flattens a nested container.
pub trait AliasMonad<F: HKT>: Monad<F> {
    /// Alias for `bind`. Chains a computation, flattening the result.
    #[inline]
    fn chain<A, B, Func>(m_a: F::Type<A>, f: Func) -> F::Type<B>
    where
        A: Satisfies<F::Constraint>,
        B: Satisfies<F::Constraint>,
        Func: FnMut(A) -> F::Type<B>,
    {
        Self::bind(m_a, f)
    }

    /// Alias for `join`. Flattens a nested container.
    #[inline]
    fn flatten<A>(m_m_a: F::Type<F::Type<A>>) -> F::Type<A>
    where
        A: Satisfies<F::Constraint>,
        F::Type<A>: Satisfies<F::Constraint>,
    {
        Self::join(m_m_a)
    }
}

// Blanket implementation
impl<T, F> AliasMonad<F> for T
where
    T: Monad<F>,
    F: HKT,
{
}
