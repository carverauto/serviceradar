/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::arrow::Arrow;
use core::marker::PhantomData;

/// Lifts a plain function `F: Fn(A) -> B` into an [`Arrow`] `A → B`.
///
/// This is the value-level counterpart of [`Morphism`](crate::Morphism)'s application:
/// `Lift::new(f)` makes `f` a first-class, composable arrow.
///
/// The input/output types `A`/`B` are carried in the type (via `PhantomData`) rather than
/// left to the `Fn` bound alone — `Fn`'s argument is not treated by the type system as
/// uniquely determined by `F`, so `Lift<F>` would be rejected (`E0207`); `Lift<A, B, F>`
/// fixes it. Use [`Lift::new`] (or the [`arrow`](crate::arrow) builder) so callers never
/// write the `PhantomData`.
pub struct Lift<A, B, F>(F, PhantomData<fn(A) -> B>);

impl<A, B, F> Lift<A, B, F>
where
    F: Fn(A) -> B,
{
    /// Lifts `f` into an arrow.
    #[inline]
    pub const fn new(f: F) -> Self {
        Lift(f, PhantomData)
    }
}

impl<A, B, F> Arrow for Lift<A, B, F>
where
    F: Fn(A) -> B,
{
    type In = A;
    type Out = B;

    #[inline]
    fn run(&self, input: A) -> B {
        (self.0)(input)
    }
}
