/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Functor, HKT, Pure, Satisfies};

/// The `Applicative` trait extends `Functor` and `Pure` by providing the `apply` operation
/// to apply a function wrapped in a context to a value wrapped in a context.
///
/// This trait is generic over `F`, which is a Higher-Kinded Type (HKT) witness.
///
/// # Hierarchy
///
/// `Applicative: Functor + Pure`
///
/// The `pure` operation is provided by the `Pure` trait, which is a supertrait.
/// This design allows `Monad` to share the same `pure` operation without requiring
/// `Monad: Applicative`.
///
/// # Constraint Support
///
/// The `apply` method requires types to satisfy the HKT's constraint.
/// This ensures type-safe application for constrained types.
///
/// # Laws (Informal)
///
/// 1.  **Identity**: `apply(pure(id), v) == v`
/// 2.  **Homomorphism**: `apply(pure(f), pure(x)) == pure(f(x))`
/// 3.  **Interchange**: `apply(u, pure(y)) == apply(pure(|f| f(y)), u)`
///
/// # Type Parameters
///
/// *   `F`: A Higher-Kinded Type (HKT) witness that represents the type constructor
///     (e.g., `OptionWitness`, `ResultWitness<E>`).
pub trait Applicative<F: HKT>: Functor<F> + Pure<F> {
    /// Applies a function wrapped in a context (`f_ab`) to a value wrapped in a context (`f_a`).
    ///
    /// This allows sequencing computations where both the function and its argument
    /// are within the same applicative context.
    ///
    /// # Arguments
    ///
    /// *   `f_ab`: An instance of `F::Type<Func>` containing the function to apply.
    /// *   `f_a`: An instance of `F::Type<A>` containing the argument for the function.
    ///
    /// # Returns
    ///
    /// An instance of `F::Type<B>` containing the result of the application,
    /// or an appropriate error/empty context if either `f_ab` or `f_a` is in an
    /// error/empty state.
    ///
    /// # Type Parameters
    ///
    /// *   `A`: The input type of the function.
    /// *   `B`: The output type of the function.
    /// *   `Func`: The type of the function, which must be `FnMut(A) -> B`.
    fn apply<A, B, Func>(f_ab: F::Type<Func>, f_a: F::Type<A>) -> F::Type<B>
    where
        A: Satisfies<F::Constraint> + Clone,
        B: Satisfies<F::Constraint>,
        Func: Satisfies<F::Constraint> + FnMut(A) -> B;
}
