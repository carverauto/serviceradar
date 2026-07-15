/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::arrow::Arrow;

/// Sequential composition `f >>> g`: the arrow that runs `f`, then `g` on its output.
///
/// Composition is **total** — `Compose<F, G>` type-checks whenever `G::In = F::Out` — and
/// `Compose` itself implements [`Arrow`], so composites compose further.
pub struct Compose<F, G>(F, G);

impl<F, G> Compose<F, G> {
    /// Builds `f >>> g`. Prefer [`Arrow::compose`].
    #[inline]
    pub const fn new(f: F, g: G) -> Self {
        Compose(f, g)
    }
}

impl<F, G> Arrow for Compose<F, G>
where
    F: Arrow,
    G: Arrow<In = F::Out>,
{
    type In = F::In;
    type Out = G::Out;

    #[inline]
    fn run(&self, input: F::In) -> G::Out {
        self.1.run(self.0.run(input))
    }
}
