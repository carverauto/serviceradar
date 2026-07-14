/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Foldable, HKT, Satisfies};

/// Alias trait for `Foldable` providing more intuitive method names.
///
/// - `reduce` → `fold`: Reduces elements to a single value.
pub trait AliasFoldable<F: HKT>: Foldable<F> {
    /// Alias for `fold`. Reduces elements to a single value.
    #[inline]
    fn reduce<A, B, Func>(fa: F::Type<A>, init: B, f: Func) -> B
    where
        A: Satisfies<F::Constraint>,
        Func: FnMut(B, A) -> B,
    {
        Self::fold(fa, init, f)
    }
}

// Blanket implementation
impl<T, F> AliasFoldable<F> for T
where
    T: Foldable<F>,
    F: HKT,
{
}
