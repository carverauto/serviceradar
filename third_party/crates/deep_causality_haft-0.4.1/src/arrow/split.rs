/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::arrow::Arrow;

/// The monoidal product `***`: runs two arrows in parallel on a pair —
/// `(A, C) → (B, D)` from `f: A → B` and `g: C → D`.
///
/// This is the operation the causal monad's `bind` cannot express: a genuine product of
/// inputs rather than a dynamically-unfolded effect. It is what makes a multi-input
/// operator (two aligned cohorts) a single composed arrow.
pub struct Split<F, G>(F, G);

impl<F, G> Split<F, G> {
    /// Builds `f *** g`. Prefer [`Arrow::split`].
    #[inline]
    pub const fn new(f: F, g: G) -> Self {
        Split(f, g)
    }
}

impl<F, G> Arrow for Split<F, G>
where
    F: Arrow,
    G: Arrow,
{
    type In = (F::In, G::In);
    type Out = (F::Out, G::Out);

    #[inline]
    fn run(&self, (a, c): (F::In, G::In)) -> (F::Out, G::Out) {
        (self.0.run(a), self.1.run(c))
    }
}
