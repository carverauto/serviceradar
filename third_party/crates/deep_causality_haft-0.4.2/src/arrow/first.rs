/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::arrow::Arrow;
use core::marker::PhantomData;

/// Strength on the first component: lifts `F: A → B` to `(A, C) → (B, C)`, passing the
/// second component through unchanged.
pub struct First<F, C>(F, PhantomData<C>);

impl<F, C> First<F, C> {
    /// Builds the `first` arrow. Prefer [`Arrow::first`].
    #[inline]
    pub const fn new(f: F) -> Self {
        First(f, PhantomData)
    }
}

impl<F, C> Arrow for First<F, C>
where
    F: Arrow,
{
    type In = (F::In, C);
    type Out = (F::Out, C);

    #[inline]
    fn run(&self, (a, c): (F::In, C)) -> (F::Out, C) {
        (self.0.run(a), c)
    }
}
