/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::arrow::Arrow;
use core::marker::PhantomData;

/// Strength on the second component: lifts `F: A → B` to `(C, A) → (C, B)`, passing the
/// first component through unchanged.
pub struct Second<F, C>(F, PhantomData<C>);

impl<F, C> Second<F, C> {
    /// Builds the `second` arrow. Prefer [`Arrow::second`].
    #[inline]
    pub const fn new(f: F) -> Self {
        Second(f, PhantomData)
    }
}

impl<F, C> Arrow for Second<F, C>
where
    F: Arrow,
{
    type In = (C, F::In);
    type Out = (C, F::Out);

    #[inline]
    fn run(&self, (c, a): (C, F::In)) -> (C, F::Out) {
        (c, self.0.run(a))
    }
}
