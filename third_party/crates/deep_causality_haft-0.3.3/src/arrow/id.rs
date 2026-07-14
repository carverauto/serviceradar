/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::arrow::Arrow;
use core::marker::PhantomData;

/// The identity arrow `A → A` — the unit of composition.
pub struct Id<A>(PhantomData<A>);

impl<A> Id<A> {
    /// Constructs the identity arrow.
    #[inline]
    pub const fn new() -> Self {
        Id(PhantomData)
    }
}

impl<A> Default for Id<A> {
    #[inline]
    fn default() -> Self {
        Id::new()
    }
}

impl<A> Arrow for Id<A> {
    type In = A;
    type Out = A;

    #[inline]
    fn run(&self, input: A) -> A {
        input
    }
}
