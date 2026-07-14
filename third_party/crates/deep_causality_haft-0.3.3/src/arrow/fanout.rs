/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::arrow::Arrow;

/// Fanout `&&&`: feeds one input to two arrows — `A → (B, C)` from `f: A → B` and
/// `g: A → C`. Requires the input to be `Clone` (it is duplicated to both arrows).
pub struct Fanout<F, G>(F, G);

impl<F, G> Fanout<F, G> {
    /// Builds `f &&& g`. Prefer [`Arrow::fanout`].
    #[inline]
    pub const fn new(f: F, g: G) -> Self {
        Fanout(f, g)
    }
}

impl<F, G> Arrow for Fanout<F, G>
where
    F: Arrow,
    G: Arrow<In = F::In>,
    F::In: Clone,
{
    type In = F::In;
    type Out = (F::Out, G::Out);

    #[inline]
    fn run(&self, input: F::In) -> (F::Out, G::Out) {
        (self.0.run(input.clone()), self.1.run(input))
    }
}
