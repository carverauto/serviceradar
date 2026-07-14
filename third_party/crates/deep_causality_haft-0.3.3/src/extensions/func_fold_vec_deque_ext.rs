/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Foldable, Functor, HKT, NoConstraint, Satisfies};
use alloc::collections::VecDeque;

/// `VecDequeWitness` is a zero-sized type that acts as a Higher-Kinded Type (HKT) witness
/// for the `VecDeque<T>` type constructor. It allows `VecDeque` to be used with generic
/// functional programming traits like `Functor` and `Foldable`.
///
/// By implementing `HKT` for `VecDequeWitness`, we can write generic functions that operate
/// on any type that has the "shape" of `VecDeque`, without knowing the inner type `T`.
///
/// # Constraint
///
/// `VecDequeWitness` uses `NoConstraint`, meaning it works with any type `T`.
pub struct VecDequeWitness;

impl HKT for VecDequeWitness {
    type Constraint = NoConstraint;

    /// Specifies that `VecDequeWitness` represents the `VecDeque<T>` type constructor.
    type Type<T> = VecDeque<T>;
}

// Implementation of Functor for VecDequeWitness
impl Functor<VecDequeWitness> for VecDequeWitness {
    /// Implements the `fmap` operation for `VecDeque<T>`.
    ///
    /// Applies the function `f` to each element in the vector deque, producing a new vector deque.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The `VecDeque` to map over.
    /// *   `f`: The function to apply to each element.
    ///
    /// # Returns
    ///
    /// A new `VecDeque` with the function applied to each of its elements.
    fn fmap<A, B, Func>(
        m_a: <VecDequeWitness as HKT>::Type<A>,
        f: Func,
    ) -> <VecDequeWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        m_a.into_iter().map(f).collect()
    }
}

// Implementation of Foldable for VecDequeWitness
impl Foldable<VecDequeWitness> for VecDequeWitness {
    /// Folds (reduces) a `VecDeque` into a single value.
    ///
    /// Applies the function `f` cumulatively to the elements of the vector deque,
    /// starting with an initial accumulator value.
    ///
    /// # Arguments
    ///
    /// *   `fa`: The `VecDeque` to fold.
    /// *   `init`: The initial accumulator value.
    /// *   `f`: The folding function.
    ///
    /// # Returns
    ///
    /// The accumulated result.
    fn fold<A, B, Func>(fa: VecDeque<A>, init: B, f: Func) -> B
    where
        Func: FnMut(B, A) -> B,
    {
        fa.into_iter().fold(init, f)
    }
}
