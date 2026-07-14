/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Applicative, CoMonad, Foldable, Functor, HKT, Monad, NoConstraint, Pure, Satisfies};
use alloc::boxed::Box;

/// `BoxWitness` is a zero-sized type that acts as a Higher-Kinded Type (HKT) witness
/// for the `Box<T>` type constructor. It allows `Box` to be used with generic
/// functional programming traits like `Functor`, `Applicative`, `Foldable`, and `Monad`.
///
/// By implementing `HKT` for `BoxWitness`, we can write generic functions that operate
/// on any type that has the "shape" of `Box`, without knowing the inner type `T`.
///
/// # Constraint
///
/// `BoxWitness` uses `NoConstraint`, meaning it works with any type `T`.
pub struct BoxWitness;

impl HKT for BoxWitness {
    type Constraint = NoConstraint;

    /// Specifies that `BoxWitness` represents the `Box<T>` type constructor.
    type Type<T> = Box<T>;
}

// Implementation of Functor for BoxWitness
impl Functor<BoxWitness> for BoxWitness {
    /// Implements the `fmap` operation for `Box<T>`.
    ///
    /// If the `Box` contains a `value`, the function `f` is applied to `value`,
    /// and the result is wrapped in a new `Box`.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The `Box` to map over.
    /// *   `f`: The function to apply to the value inside the `Box`.
    ///
    /// # Returns
    ///
    /// A new `Box` with the function applied to its content.
    fn fmap<A, B, Func>(
        m_a: <BoxWitness as HKT>::Type<A>,
        mut f: Func,
    ) -> <BoxWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        Box::new(f(*m_a))
    }
}

// Implementation of Pure for BoxWitness
impl Pure<BoxWitness> for BoxWitness {
    /// Lifts a pure value into a `Box`.
    fn pure<T>(value: T) -> <BoxWitness as HKT>::Type<T>
    where
        T: Satisfies<NoConstraint>,
    {
        Box::new(value)
    }
}

// Implementation of Applicative for BoxWitness
impl Applicative<BoxWitness> for BoxWitness {
    /// Applies a function wrapped in a `Box` (`f_ab`) to a value wrapped in a `Box` (`f_a`).
    fn apply<A, B, Func>(
        mut f_ab: <BoxWitness as HKT>::Type<Func>,
        f_a: <BoxWitness as HKT>::Type<A>,
    ) -> <BoxWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        Func: Satisfies<NoConstraint> + FnMut(A) -> B,
    {
        Box::new((*f_ab)(*f_a))
    }
}

// Implementation of Foldable for BoxWitness
impl Foldable<BoxWitness> for BoxWitness {
    /// Folds (reduces) a `Box` into a single value.
    ///
    /// The function `f` is applied with the initial accumulator and the `value` inside the `Box`.
    ///
    /// # Arguments
    ///
    /// *   `fa`: The `Box` to fold.
    /// *   `init`: The initial accumulator value.
    /// *   `f`: The folding function.
    ///
    /// # Returns
    ///
    /// The accumulated result.
    fn fold<A, B, Func>(fa: Box<A>, init: B, mut f: Func) -> B
    where
        Func: FnMut(B, A) -> B,
    {
        f(init, *fa)
    }
}

// Implementation of Monad for BoxWitness
impl Monad<BoxWitness> for BoxWitness {
    /// Implements the `bind` operation for `Box<T>`.
    fn bind<A, B, Func>(
        m_a: <BoxWitness as HKT>::Type<A>,
        mut f: Func,
    ) -> <BoxWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> <BoxWitness as HKT>::Type<B>,
    {
        f(*m_a)
    }
}

// Implementation of CoMonad for BoxWitness
impl CoMonad<BoxWitness> for BoxWitness {
    fn extract<A>(fa: &<Self as HKT>::Type<A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        *fa.clone()
    }

    fn extend<A, B, Func>(fa: &<Self as HKT>::Type<A>, mut f: Func) -> <Self as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        Func: FnMut(&<Self as HKT>::Type<A>) -> B,
    {
        Box::new(f(fa))
    }
}
