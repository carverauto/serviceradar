/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{
    Applicative, Foldable, Functor, HKT, Monad, NoConstraint, Pure, Satisfies, Traversable,
};

/// `OptionWitness` is a zero-sized type that acts as a Higher-Kinded Type (HKT) witness
/// for the `Option<T>` type constructor. It allows `Option` to be used with generic
/// functional programming traits like `Functor`, `Applicative`, `Foldable`, and `Monad`.
///
/// By implementing `HKT` for `OptionWitness`, we can write generic functions that operate
/// on any type that has the "shape" of `Option`, without knowing the inner type `T`.
///
/// # Constraint
///
/// `OptionWitness` uses `NoConstraint`, meaning it works with any type `T`.
pub struct OptionWitness;

impl HKT for OptionWitness {
    type Constraint = NoConstraint;

    /// Specifies that `OptionWitness` represents the `Option<T>` type constructor.
    type Type<T> = Option<T>;
}

// Implementation of Functor for OptionWitness
impl Functor<OptionWitness> for OptionWitness {
    /// Implements the `fmap` operation for `Option<T>`.
    ///
    /// If the `Option` is `Some(value)`, the function `f` is applied to `value`,
    /// and the result is wrapped in `Some`. If the `Option` is `None`, `None` is returned.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The `Option` to map over.
    /// *   `f`: The function to apply to the value inside the `Option`.
    ///
    /// # Returns
    ///
    /// A new `Option` with the function applied to its content, or `None`.
    fn fmap<A, B, Func>(
        m_a: <OptionWitness as HKT>::Type<A>,
        f: Func,
    ) -> <OptionWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        m_a.map(f)
    }
}

// Implementation of Pure for OptionWitness
impl Pure<OptionWitness> for OptionWitness {
    /// Lifts a pure value into a `Some` variant of `Option`.
    ///
    /// # Arguments
    ///
    /// *   `value`: The value to wrap in `Some`.
    ///
    /// # Returns
    ///
    /// `Some(value)`.
    fn pure<T>(value: T) -> <OptionWitness as HKT>::Type<T>
    where
        T: Satisfies<NoConstraint>,
    {
        Some(value)
    }
}

// Implementation of Applicative for OptionWitness
impl Applicative<OptionWitness> for OptionWitness {
    /// Applies a function wrapped in an `Option` (`f_ab`) to a value wrapped in an `Option` (`f_a`).
    ///
    /// If both `f_ab` and `f_a` are `Some`, the function is applied to the value.
    /// If either is `None`, `None` is returned.
    ///
    /// # Arguments
    ///
    /// *   `f_ab`: An `Option` containing the function.
    /// *   `f_a`: An `Option` containing the argument.
    ///
    /// # Returns
    ///
    /// An `Option` containing the result of the application, or `None`.
    fn apply<A, B, Func>(
        f_ab: <OptionWitness as HKT>::Type<Func>,
        f_a: <OptionWitness as HKT>::Type<A>,
    ) -> <OptionWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        Func: Satisfies<NoConstraint> + FnMut(A) -> B,
    {
        f_ab.and_then(|f| f_a.map(f))
    }
}

// Implementation of Foldable for OptionWitness
impl Foldable<OptionWitness> for OptionWitness {
    /// Folds (reduces) an `Option` into a single value.
    ///
    /// If the `Option` is `Some(value)`, the function `f` is applied with the initial
    /// accumulator and the `value`. If the `Option` is `None`, the initial accumulator
    /// is returned.
    ///
    /// # Arguments
    ///
    /// *   `fa`: The `Option` to fold.
    /// *   `init`: The initial accumulator value.
    /// *   `f`: The folding function.
    ///
    /// # Returns
    ///
    /// The accumulated result.
    fn fold<A, B, Func>(fa: Option<A>, init: B, mut f: Func) -> B
    where
        Func: FnMut(B, A) -> B,
    {
        match fa {
            Some(a) => f(init, a),
            None => init,
        }
    }
}

// Implementation of Monad for OptionWitness
impl Monad<OptionWitness> for OptionWitness {
    /// Implements the `bind` (or `and_then`) operation for `Option<T>`.
    ///
    /// If the `Option` is `Some(value)`, the function `f` is applied to `value`,
    /// which itself returns an `Option`. If the `Option` is `None`, `None` is returned.
    /// This effectively chains computations that might fail.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The initial `Option`.
    /// *   `f`: A function that takes the inner value of `m_a` and returns a new `Option`.
    ///
    /// # Returns
    ///
    /// A new `Option` representing the chained computation.
    fn bind<A, B, Func>(
        m_a: <OptionWitness as HKT>::Type<A>,
        mut f: Func,
    ) -> <OptionWitness as HKT>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> <OptionWitness as HKT>::Type<B>,
    {
        match m_a {
            Some(a) => f(a),
            None => None,
        }
    }
}

// Implementation of Traversable for OptionWitness
impl Traversable<OptionWitness> for OptionWitness {
    fn sequence<A, M>(
        fa: <OptionWitness as HKT>::Type<M::Type<A>>,
    ) -> <M as HKT>::Type<<OptionWitness as HKT>::Type<A>>
    where
        M: Applicative<M> + HKT,
        A: Clone + Satisfies<NoConstraint> + Satisfies<M::Constraint>,
        M::Type<A>: Satisfies<NoConstraint>,
        Option<A>: Satisfies<M::Constraint>,
    {
        match fa {
            Some(m_a) => M::fmap(m_a, |a_val: A| Some(a_val)),
            None => M::pure(None),
        }
    }
}
