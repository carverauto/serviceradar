/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Functor, HKT, Satisfies};

/// Alias trait for `Functor` providing more intuitive method names.
///
/// - `transform` → `fmap`: Applies a function to the value inside a container.
pub trait AliasFunctor<F: HKT>: Functor<F> {
    /// Alias for `fmap`. Transforms the value inside a container.
    #[inline]
    fn transform<A, B, Func>(m_a: F::Type<A>, f: Func) -> F::Type<B>
    where
        A: Satisfies<F::Constraint>,
        B: Satisfies<F::Constraint>,
        Func: FnMut(A) -> B,
    {
        Self::fmap(m_a, f)
    }
}

// Blanket implementation
impl<T, F> AliasFunctor<F> for T
where
    T: Functor<F>,
    F: HKT,
{
}
