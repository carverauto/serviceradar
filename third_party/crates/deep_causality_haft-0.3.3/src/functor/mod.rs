/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{HKT, Satisfies};

/// The `Functor` trait abstracts over types that can be mapped over.
///
/// It provides the `fmap` operation, which applies a function to the value
/// inside a type constructor, preserving the structure of the type.
///
/// This trait is generic over `F`, which is a Higher-Kinded Type (HKT) witness.
///
/// # Constraint Support
///
/// The `fmap` function now requires both input type `A` and output type `B`
/// to satisfy the HKT's constraint. This ensures type-safe mapping for
/// constrained types like `CausalTensor<T>` where `T: TensorData`.
///
/// # Laws (Informal)
///
/// 1.  **Identity**: `fmap(id, fa) == fa`
/// 2.  **Composition**: `fmap(f.compose(g), fa) == fmap(f, fmap(g, fa))`
///
/// # Type Parameters
///
/// *   `F`: A Higher-Kinded Type (HKT) witness that represents the type constructor
///     (e.g., `OptionWitness`, `ResultWitness<E>`, `VecWitness`).
pub trait Functor<F: HKT> {
    /// Applies a function `f` to the value inside the container `m_a`.
    ///
    /// This operation transforms the inner value of the type constructor
    /// without changing its overall structure.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The instance of the type constructor (`F::Type<A>`) to map over.
    /// *   `f`: The function to apply to the inner value of `m_a`.
    ///
    /// # Returns
    ///
    /// A new instance of `F::Type<B>` with the function `f` applied to the inner value.
    ///
    /// # Type Parameters
    ///
    /// *   `A`: The original type of the value inside the container.
    /// *   `B`: The new type of the value after applying the function `f`.
    /// *   `Func`: The type of the mapping function, which must be `FnMut(A) -> B`.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use deep_causality_haft::{Functor, OptionWitness, HKT};
    ///
    /// let opt_a: Option<<OptionWitness as HKT>::Type<i32>> = Some(Some(5));
    /// let f = |x| x * 2;
    /// let opt_b = OptionWitness::fmap(opt_a.unwrap(), f);
    /// assert_eq!(opt_b, Some(10));
    ///
    /// let opt_none: Option<<OptionWitness as HKT>::Type<i32>> = Some(None);
    /// let opt_none_mapped = OptionWitness::fmap(opt_none.unwrap(), f);
    /// assert_eq!(opt_none_mapped, None);
    /// ```
    fn fmap<A, B, Func>(m_a: F::Type<A>, f: Func) -> F::Type<B>
    where
        A: Satisfies<F::Constraint>,
        B: Satisfies<F::Constraint>,
        Func: FnMut(A) -> B;
}
