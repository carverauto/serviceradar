/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::io::IoAction;
use core::marker::PhantomData;

/// The unit of the IO monad: an action that yields `value` with no side effect.
///
/// The error type `E` is carried in the type (via `PhantomData`) rather than inferred, since it is
/// not determined by the stored value; use [`pure`] so callers never write the `PhantomData`.
pub struct IoPure<A, E>(A, PhantomData<fn() -> E>);

impl<A, E> IoPure<A, E> {
    /// Lifts `value` into an IO action. Prefer the free [`pure`] constructor.
    #[inline]
    pub const fn new(value: A) -> Self {
        IoPure(value, PhantomData)
    }
}

impl<A, E> IoAction for IoPure<A, E> {
    type Output = A;
    type Error = E;

    #[inline]
    fn run(self) -> Result<A, E> {
        Ok(self.0)
    }
}

/// Lift a value into the IO monad: the action that yields `value` and performs no IO.
#[inline]
pub fn pure<A, E>(value: A) -> IoPure<A, E> {
    IoPure::new(value)
}
