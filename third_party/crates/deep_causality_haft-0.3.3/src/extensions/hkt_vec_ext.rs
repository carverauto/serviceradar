/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Applicative, Foldable, Functor, HKT, Monad, NoConstraint, Pure, Satisfies};
use alloc::vec;
use alloc::vec::Vec;

/// `VecWitness` is a zero-sized type that acts as a Higher-Kinded Type (HKT) witness
/// for the `Vec<T>` type constructor. It allows `Vec` to be used with generic
/// functional programming traits like `Functor`, `Applicative`, `Foldable`, and `Monad`.
///
/// By implementing `HKT` for `VecWitness`, we can write generic functions that operate
/// on any type that has the "shape" of `Vec`, without knowing the inner type `T`.
///
/// # Constraint
///
/// `VecWitness` uses `NoConstraint`, meaning it works with any type `T`.
pub struct VecWitness;

impl HKT for VecWitness {
    type Constraint = NoConstraint;

    /// Specifies that `VecWitness` represents the `Vec<T>` type constructor.
    type Type<T> = Vec<T>;
}

// Implementation of Pure for VecWitness
impl Pure<VecWitness> for VecWitness {
    /// Lifts a pure value into a `Vec` containing only that value.
    fn pure<T>(value: T) -> <VecWitness as HKT>::Type<T>
    where
        T: Satisfies<NoConstraint>,
    {
        vec![value]
    }
}

// Implementation of Applicative for VecWitness
impl Applicative<VecWitness> for VecWitness {
    /// Applies a vector of functions (`f_ab`) to a vector of values (`f_a`).
    ///
    /// Each function in `f_ab` is applied to each value in `f_a`, producing a new vector
    /// containing all possible combinations of applications.
    fn apply<A, B, Func>(
        f_ab: <VecWitness as HKT>::Type<Func>,
        f_a: <VecWitness as HKT>::Type<A>,
    ) -> <VecWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        Func: Satisfies<NoConstraint> + FnMut(A) -> B,
    {
        f_ab.into_iter()
            .flat_map(|mut f_val| {
                f_a.iter()
                    .map(move |a_val| f_val(a_val.clone()))
                    .collect::<Vec<B>>()
            })
            .collect()
    }
}

// Implementation of Functor for VecWitness
impl Functor<VecWitness> for VecWitness {
    /// Implements the `fmap` operation for `Vec<T>`.
    ///
    /// Applies the function `f` to each element in the vector, producing a new vector.
    fn fmap<A, B, Func>(m_a: <VecWitness as HKT>::Type<A>, f: Func) -> <VecWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        m_a.into_iter().map(f).collect()
    }
}

// Implementation of Foldable for VecWitness
impl Foldable<VecWitness> for VecWitness {
    /// Folds (reduces) a `Vec` into a single value.
    fn fold<A, B, Func>(fa: <VecWitness as HKT>::Type<A>, init: B, f: Func) -> B
    where
        <VecWitness as HKT>::Type<A>: IntoIterator<Item = A>,
        A: Satisfies<NoConstraint>,
        Func: FnMut(B, A) -> B,
    {
        fa.into_iter().fold(init, f)
    }
}

// Implementation of Monad for VecWitness
impl Monad<VecWitness> for VecWitness {
    /// Implements the `bind` (or `flat_map`) operation for `Vec<T>`.
    ///
    /// Applies the function `f` to each element in the vector, where `f` itself
    /// returns a new vector. All the resulting vectors are then concatenated into a single `Vec`.
    fn bind<A, B, Func>(m_a: <VecWitness as HKT>::Type<A>, f: Func) -> <VecWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> <VecWitness as HKT>::Type<B>,
    {
        m_a.into_iter().flat_map(f).collect()
    }
}

// NOTE: Traversable is not implmented for VecWitness
