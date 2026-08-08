/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT2Unbound, Profunctor, Satisfies};

/// Alias trait for `Profunctor` providing more intuitive method names.
///
/// - `adapt` → `dimap`: Adapts both input and output.
/// - `preprocess` → `lmap`: Pre-processes the input.
/// - `postprocess` → `rmap`: Post-processes the output.
pub trait AliasProfunctor<P: HKT2Unbound>: Profunctor<P> {
    /// Alias for `dimap`. Adapts both input and output.
    #[inline]
    fn adapt<A, B, C, D, F1, F2>(pab: P::Type<A, B>, f_pre: F1, f_post: F2) -> P::Type<C, D>
    where
        A: 'static + Satisfies<P::Constraint>,
        B: 'static + Satisfies<P::Constraint>,
        C: 'static + Satisfies<P::Constraint>,
        D: 'static + Satisfies<P::Constraint>,
        F1: FnMut(C) -> A + 'static,
        F2: FnMut(B) -> D + 'static,
    {
        Self::dimap(pab, f_pre, f_post)
    }

    /// Alias for `lmap`. Pre-processes the input.
    #[inline]
    fn preprocess<A, B, C, F1>(pab: P::Type<A, B>, f_pre: F1) -> P::Type<C, B>
    where
        A: 'static + Satisfies<P::Constraint>,
        B: 'static + Satisfies<P::Constraint> + Clone,
        C: 'static + Satisfies<P::Constraint>,
        F1: FnMut(C) -> A + 'static,
    {
        Self::lmap(pab, f_pre)
    }

    /// Alias for `rmap`. Post-processes the output.
    #[inline]
    fn postprocess<A, B, D, F2>(pab: P::Type<A, B>, f_post: F2) -> P::Type<A, D>
    where
        A: 'static + Satisfies<P::Constraint> + Clone,
        B: 'static + Satisfies<P::Constraint>,
        D: 'static + Satisfies<P::Constraint>,
        F2: FnMut(B) -> D + 'static,
    {
        Self::rmap(pab, f_post)
    }
}

// Blanket implementation
impl<T, P> AliasProfunctor<P> for T
where
    T: Profunctor<P>,
    P: HKT2Unbound,
{
}
