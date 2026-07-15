/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::io::IoAction;
use core::marker::PhantomData;

/// The zero of the IO monad: an action that fails with `error` and performs no side effect.
///
/// The output type `A` is carried in the type (via `PhantomData`) rather than inferred, since it is
/// not determined by the stored error; use [`fail`] so callers never write the `PhantomData`.
pub struct IoFail<A, E>(E, PhantomData<fn() -> A>);

impl<A, E> IoFail<A, E> {
    /// Builds the failing action. Prefer the free [`fail`] constructor.
    #[inline]
    pub const fn new(error: E) -> Self {
        IoFail(error, PhantomData)
    }
}

impl<A, E> IoAction for IoFail<A, E> {
    type Output = A;
    type Error = E;

    #[inline]
    fn run(self) -> Result<A, E> {
        Err(self.0)
    }
}

/// Build a failing IO action: the action that yields `error` and performs no IO.
#[inline]
pub fn fail<A, E>(error: E) -> IoFail<A, E> {
    IoFail::new(error)
}
