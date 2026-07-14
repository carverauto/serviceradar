/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{
    Applicative, Foldable, Functor, HKT, HKT2, Monad, NoConstraint, Placeholder, Pure, Satisfies,
    Traversable,
};

/// `ResultWitness<E>` is a zero-sized type that acts as a Higher-Kinded Type (HKT) witness
/// for the `Result<T, E>` type constructor, where the error type `E` is fixed.
///
/// It allows `Result` to be used with generic functional programming traits like `Functor`,
/// `Applicative`, `Foldable`, and `Monad` by fixing one of its type parameters.
///
/// # Constraint
///
/// `ResultWitness` uses `NoConstraint`, meaning it works with any type `T`.
pub struct ResultWitness<E>(Placeholder, E);

impl<E> HKT2<E> for ResultWitness<E> {
    /// Specifies that `ResultWitness<E>` represents the `Result<T, E>` type constructor
    /// with a fixed error type `E`.
    type Type<T> = Result<T, E>;
}

impl<E> HKT for ResultWitness<E> {
    type Constraint = NoConstraint;

    /// Specifies that `ResultWitness<E>` also acts as a single-parameter HKT,
    /// where the `E` parameter is considered part of the "witness" itself.
    type Type<T> = Result<T, E>;
}

// Implementation of Functor for ResultWitness
impl<E> Functor<ResultWitness<E>> for ResultWitness<E>
where
    E: 'static,
{
    /// Implements the `fmap` operation for `Result<T, E>`.
    ///
    /// If the `Result` is `Ok(value)`, the function `f` is applied to `value`,
    /// and the result is wrapped in `Ok`. If the `Result` is `Err(error)`, `Err(error)` is returned.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The `Result` to map over.
    /// *   `f`: The function to apply to the value inside the `Result`.
    ///
    /// # Returns
    ///
    /// A new `Result` with the function applied to its content, or the original `Err`.
    fn fmap<A, B, Func>(
        m_a: <ResultWitness<E> as HKT2<E>>::Type<A>,
        f: Func,
    ) -> <ResultWitness<E> as HKT2<E>>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        m_a.map(f)
    }
}

// Implementation of Pure for ResultWitness
impl<E> Pure<ResultWitness<E>> for ResultWitness<E>
where
    E: 'static + Clone,
{
    /// Lifts a pure value into an `Ok` variant of `Result`.
    fn pure<T>(value: T) -> <ResultWitness<E> as HKT2<E>>::Type<T>
    where
        T: Satisfies<NoConstraint>,
    {
        Ok(value)
    }
}

// Implementation of Applicative for ResultWitness
impl<E> Applicative<ResultWitness<E>> for ResultWitness<E>
where
    E: 'static + Clone,
{
    /// Applies a function wrapped in a `Result` (`f_ab`) to a value wrapped in a `Result` (`f_a`).
    fn apply<A, B, Func>(
        f_ab: <ResultWitness<E> as HKT2<E>>::Type<Func>,
        f_a: <ResultWitness<E> as HKT2<E>>::Type<A>,
    ) -> <ResultWitness<E> as HKT2<E>>::Type<B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        Func: Satisfies<NoConstraint> + FnMut(A) -> B,
    {
        match f_ab {
            Ok(mut f) => match f_a {
                Ok(a) => Ok(f(a)),
                Err(e) => Err(e),
            },
            Err(e) => Err(e),
        }
    }
}

// Implementation of Foldable for ResultWitness
impl<E> Foldable<ResultWitness<E>> for ResultWitness<E>
where
    E: 'static,
{
    /// Folds (reduces) a `Result` into a single value.
    ///
    /// If the `Result` is `Ok(value)`, the function `f` is applied with the initial
    /// accumulator and the `value`. If the `Result` is `Err`, the initial accumulator
    /// is returned.
    ///
    /// # Arguments
    ///
    /// *   `fa`: The `Result` to fold.
    /// *   `init`: The initial accumulator value.
    /// *   `f`: The folding function.
    ///
    /// # Returns
    ///
    /// The accumulated result.
    fn fold<A, B, Func>(fa: Result<A, E>, init: B, mut f: Func) -> B
    where
        Func: FnMut(B, A) -> B,
    {
        match fa {
            Ok(a) => f(init, a),
            Err(_) => init,
        }
    }
}

// Implementation of Monad for ResultWitness
impl<E> Monad<ResultWitness<E>> for ResultWitness<E>
where
    E: 'static + Clone,
{
    /// Implements the `bind` (or `and_then`) operation for `Result<T, E>`.
    ///
    /// If the `Result` is `Ok(value)`, the function `f` is applied to `value`,
    /// which itself returns a `Result`. If the `Result` is `Err(error)`, `Err(error)` is returned.
    /// This effectively chains computations that might fail, propagating the first error.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The initial `Result`.
    /// *   `f`: A function that takes the inner value of `m_a` and returns a new `Result`.
    ///
    /// # Returns
    ///
    /// A new `Result` representing the chained computation.
    fn bind<A, B, Func>(
        m_a: <ResultWitness<E> as HKT2<E>>::Type<A>,
        mut f: Func,
    ) -> <ResultWitness<E> as HKT2<E>>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> <ResultWitness<E> as HKT2<E>>::Type<B>,
    {
        match m_a {
            Ok(a) => f(a),
            Err(e) => Err(e),
        }
    }
}

// Implementation of Traversable for ResultWitness
impl<E> Traversable<ResultWitness<E>> for ResultWitness<E>
where
    E: 'static + Clone, // E needs to be clonable for Err propagation
{
    fn sequence<A, M>(
        fa: <ResultWitness<E> as HKT2<E>>::Type<M::Type<A>>,
    ) -> <M as HKT>::Type<<ResultWitness<E> as HKT2<E>>::Type<A>>
    where
        M: Applicative<M> + HKT,
        A: Clone + Satisfies<NoConstraint> + Satisfies<M::Constraint>,
        M::Type<A>: Satisfies<NoConstraint>,
        Result<A, E>: Satisfies<M::Constraint>,
    {
        match fa {
            Ok(m_a) => M::fmap(m_a, |a_val: A| Ok(a_val)),
            Err(e) => M::pure(Err(e.clone())),
        }
    }
}

// -----------------------------------------------------------------------------
// Unbound HKT Extensions (Arity 2)
// -----------------------------------------------------------------------------

use crate::{Bifunctor, HKT2Unbound};

/// `ResultUnboundWitness` is a zero-sized type that acts as a witness for the
/// `Result<A, B>` type constructor where *both* parameters are unbound.
pub struct ResultUnboundWitness;

impl HKT2Unbound for ResultUnboundWitness {
    type Constraint = NoConstraint;
    type Type<A, B> = Result<A, B>;
}

impl Bifunctor<ResultUnboundWitness> for ResultUnboundWitness {
    fn bimap<A, B, C, D, F1, F2>(fab: Result<A, B>, mut f1: F1, mut f2: F2) -> Result<C, D>
    where
        F1: FnMut(A) -> C,
        F2: FnMut(B) -> D,
    {
        match fab {
            Ok(a) => Ok(f1(a)),
            Err(b) => Err(f2(b)),
        }
    }
}
