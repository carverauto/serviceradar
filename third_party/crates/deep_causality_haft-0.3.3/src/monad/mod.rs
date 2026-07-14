/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Functor, HKT, Pure, Satisfies};

/// The `Monad` trait extends `Functor` and `Pure` by providing the `bind` operation
/// for sequencing computations that produce effectful values.
///
/// # Design Note: Pure-Based Hierarchy
///
/// Unlike the Haskell convention (`Monad: Applicative`), this trait extends `Functor + Pure`
/// directly. This enables **strict constrained witnesses** (like `StrictCausalTensorWitness`)
/// to implement `Monad` without being blocked by `Applicative`'s closure constraint.
///
/// Both `Applicative` and `Monad` share the same `pure` operation via the `Pure` trait.
///
/// # Constraint Support
///
/// The `bind` method requires types to satisfy the HKT's constraint. This ensures type-safe
/// chaining for constrained types like `CausalTensor<T>` where `T: TensorData`.
///
/// # Laws (Informal)
///
/// 1.  **Left Identity**: `bind(pure(a), f) == f(a)`
/// 2.  **Right Identity**: `bind(m, pure) == m`
/// 3.  **Associativity**: `bind(bind(m, f), g) == bind(m, |x| bind(f(x), g))`
///
/// # Type Parameters
///
/// *   `F`: A Higher-Kinded Type (HKT) witness that represents the type constructor
///     (e.g., `OptionWitness`, `ResultWitness<E>`, `VecWitness`).
pub trait Monad<F: HKT>: Functor<F> + Pure<F> {
    /// Chains a computation from an effectful value, flattening the result.
    /// This is the core sequencing operation of a Monad.
    ///
    /// The `bind` method takes an effectful value (`m_a`) and a function `f`.
    /// The function `f` takes the inner value of `m_a` and returns a new effectful value.
    /// `bind` then flattens this nested structure into a single effectful value.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The initial effectful value (`F::Type<A>`).
    /// *   `f`: A function that takes the inner value of `m_a` and returns a new effectful value (`F::Type<B>`).
    ///
    /// # Returns
    ///
    /// A new effectful value (`F::Type<B>`) representing the chained and flattened computation.
    ///
    /// # Type Parameters
    ///
    /// *   `A`: The type of the value inside the initial effectful context.
    /// *   `B`: The type of the value inside the resulting effectful context.
    /// *   `Func`: The type of the binding function, which must be `FnMut(A) -> F::Type<B>`.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use deep_causality_haft::{Monad, OptionWitness, HKT};
    ///
    /// let opt_a: Option<<OptionWitness as HKT>::Type<i32>> = Some(Some(5));
    /// let f = |x| Some(x * 2);
    /// let opt_b = OptionWitness::bind(opt_a.unwrap(), f);
    /// assert_eq!(opt_b, Some(10));
    ///
    /// let opt_none: Option<<OptionWitness as HKT>::Type<i32>> = Some(None);
    /// let opt_none_bound = OptionWitness::bind(opt_none.unwrap(), f);
    /// assert_eq!(opt_none_bound, None);
    /// ```
    fn bind<A, B, Func>(m_a: F::Type<A>, f: Func) -> F::Type<B>
    where
        A: Satisfies<F::Constraint>,
        B: Satisfies<F::Constraint>,
        Func: FnMut(A) -> F::Type<B>;

    /// Flatten a nested structure into a single layer.
    ///
    /// Default implementation using `bind` with identity function.
    ///
    /// # Arguments
    ///
    /// *   `m_m_a`: A nested effectful value (`F::Type<F::Type<A>>`).
    ///
    /// # Returns
    ///
    /// A flattened effectful value (`F::Type<A>`).
    fn join<A>(m_m_a: F::Type<F::Type<A>>) -> F::Type<A>
    where
        A: Satisfies<F::Constraint>,
        F::Type<A>: Satisfies<F::Constraint>,
    {
        Self::bind(m_m_a, |x| x)
    }
}
