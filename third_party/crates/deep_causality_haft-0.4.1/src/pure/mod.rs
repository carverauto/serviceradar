/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{HKT, Satisfies};

/// The `Pure` trait provides the ability to lift a value into a context.
///
/// This is the fundamental "return" or "unit" operation in category theory,
/// representing the natural transformation η: Id → F.
///
/// # Law (Informal)
///
/// **Naturality**: `fmap(pure(a), f) == pure(f(a))` — the square `fmap f ∘ η = η ∘ f`
/// commutes for every pure `f`. This is what makes `pure` a *natural* transformation rather
/// than an arbitrary family of injections (Mac Lane, CWM §I.4). Machine-checked in
/// `lean/DeepCausalityFormal/Haft/Pure.lean`.
///
/// # Design Rationale
///
/// `Pure` is extracted as a separate trait to enable:
/// - `Applicative: Functor + Pure` (for `apply` operations)
/// - `Monad: Functor + Pure` (for `bind` operations)
///
/// This allows `Monad` to be implemented without requiring `Applicative`,
/// which is blocked for strict constrained witnesses due to the
/// `Func: Satisfies<F::Constraint>` requirement in `Applicative::apply`.
///
/// # Constraint Support
///
/// The `pure` function requires the value type to satisfy the HKT's constraint.
/// This ensures type-safe lifting for constrained types like `CausalTensor<T>`
/// where `T: TensorData`.
///
/// # Type Parameters
///
/// *   `F`: A Higher-Kinded Type (HKT) witness that represents the type constructor
///     (e.g., `OptionWitness`, `VecWitness`, `CausalTensorWitness`).
pub trait Pure<F: HKT> {
    /// Lifts a pure value into the context `F::Type<T>`.
    ///
    /// This is the "return" operation, introducing a value into
    /// the minimal effectful or container context.
    ///
    /// # Arguments
    ///
    /// *   `value`: The pure value to lift.
    ///
    /// # Returns
    ///
    /// An instance of `F::Type<T>` containing the `value`.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use deep_causality_haft::{Pure, OptionWitness, HKT};
    ///
    /// let opt: Option<i32> = OptionWitness::pure(42);
    /// assert_eq!(opt, Some(42));
    /// ```
    fn pure<T>(value: T) -> F::Type<T>
    where
        T: Satisfies<F::Constraint>;
}
