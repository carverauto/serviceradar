/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Effect3, Effect4, Effect5, Functor, HKT3, HKT4, HKT5};

// ----------------------------------------------------
// Monad Effect Traits (Arity 3)
// ----------------------------------------------------

/// Monadic logic for an Arity 3 type after it has been partially applied via `Effect3`.
///
/// This trait provides the `pure` and `bind` operations for type-encoded effect systems
/// that track two fixed effect types (e.g., Error and Warning/Log) alongside a primary value.
/// It enables sequencing computations within such an effectful context.
///
/// # Type Parameters
///
/// *   `E`: A type that implements the `Effect3` trait, providing the fixed effect types
///     and the HKT witness for the underlying type constructor.
pub trait MonadEffect3<E: Effect3>
where
    E::HktWitness: Functor<E::HktWitness> + Sized,
{
    /// Lifts a pure value into the DSL's Effect container (arity 3).
    ///
    /// This creates an effectful value with no initial errors or warnings, containing
    /// only the provided pure value.
    ///
    /// # Arguments
    ///
    /// *   `value`: The pure value to lift.
    ///
    /// # Returns
    ///
    /// An effectful value of type `E::HktWitness::Type<T>`.
    fn pure<T>(value: T) -> <E::HktWitness as HKT3<E::Fixed1, E::Fixed2>>::Type<T>;

    /// The core sequencing operation for arity 3 effect systems.
    ///
    /// This method chains a computation `f` to an existing effectful value `effect`.
    /// If `effect` contains an error, the error is propagated. Otherwise, the function `f`
    /// is applied to the value within `effect`, and any warnings/logs are combined.
    ///
    /// # Arguments
    ///
    /// *   `effect`: The initial effectful value.
    /// *   `f`: A function that takes the inner value of `effect` and returns a new effectful value.
    ///
    /// # Returns
    ///
    /// A new effectful value representing the chained computation.
    ///
    /// # Type Parameters
    ///
    /// *   `T`: The type of the value inside the initial effect.
    /// *   `U`: The type of the value inside the resulting effect.
    /// *   `Func`: The type of the binding function.
    fn bind<T, U, Func>(
        effect: <E::HktWitness as HKT3<E::Fixed1, E::Fixed2>>::Type<T>,
        f: Func,
    ) -> <E::HktWitness as HKT3<E::Fixed1, E::Fixed2>>::Type<U>
    where
        Func: FnMut(T) -> <E::HktWitness as HKT3<E::Fixed1, E::Fixed2>>::Type<U>,
        U: Default;
}

// ----------------------------------------------------
// Monad Effect Traits (Arity 4)
// ----------------------------------------------------

/// Monadic logic for an Arity 4 type after it has been partially applied via `Effect4`.
///
/// This trait provides the `pure` and `bind` operations for type-encoded effect systems
/// that track three fixed effect types (e.g., Error, Log, Counter) alongside a primary value.
/// It enables sequencing computations within such an effectful context.
///
/// # Type Parameters
///
/// *   `E`: A type that implements the `Effect4` trait, providing the fixed effect types
///     and the HKT witness for the underlying type constructor.
pub trait MonadEffect4<E: Effect4>
where
    E::HktWitness: Functor<E::HktWitness> + Sized,
{
    /// Lifts a pure value into an Effect container (arity 4).
    ///
    /// This creates an effectful value with no initial errors, logs, or counters,
    /// containing only the provided pure value.
    ///
    /// # Arguments
    ///
    /// *   `value`: The pure value to lift.
    ///
    /// # Returns
    ///
    /// An effectful value of type `E::HktWitness::Type<T>`.
    fn pure<T>(value: T) -> <E::HktWitness as HKT4<E::Fixed1, E::Fixed2, E::Fixed3>>::Type<T>;

    /// The core sequencing operation for arity 4 effect systems.
    ///
    /// This method chains a computation `f` to an existing effectful value `effect`.
    /// If `effect` contains an error, the error is propagated. Otherwise, the function `f`
    /// is applied to the value within `effect`, and any logs/counters are combined.
    ///
    /// # Arguments
    ///
    /// *   `effect`: The initial effectful value.
    /// *   `f`: A function that takes the inner value of `effect` and returns a new effectful value.
    ///
    /// # Returns
    ///
    /// A new effectful value representing the chained computation.
    ///
    /// # Type Parameters
    ///
    /// *   `T`: The type of the value inside the initial effect.
    /// *   `U`: The type of the value inside the resulting effect.
    /// *   `Func`: The type of the binding function.
    fn bind<T, U, Func>(
        effect: <E::HktWitness as HKT4<E::Fixed1, E::Fixed2, E::Fixed3>>::Type<T>,
        f: Func,
    ) -> <E::HktWitness as HKT4<E::Fixed1, E::Fixed2, E::Fixed3>>::Type<U>
    where
        Func: FnMut(T) -> <E::HktWitness as HKT4<E::Fixed1, E::Fixed2, E::Fixed3>>::Type<U>,
        U: Default;
}

// ----------------------------------------------------
// Monad Effect Traits (Arity 5)
// ----------------------------------------------------

/// Monadic logic for an Arity 5 type after it has been partially applied via `Effect5`.
///
/// This trait provides the `pure` and `bind` operations for type-encoded effect systems
/// that track four fixed effect types (e.g., Error, Log, Counter, Trace) alongside a primary value.
/// It enables sequencing computations within such an effectful context.
///
/// # Type Parameters
///
/// *   `E`: A type that implements the `Effect5` trait, providing the fixed effect types
///     and the HKT witness for the underlying type constructor.
pub trait MonadEffect5<E: Effect5>
where
    E::HktWitness: Functor<E::HktWitness> + Sized,
{
    /// Lifts a pure value into an Effect container (arity 5).
    ///
    /// This creates an effectful value with no initial errors, logs, counters, or traces,
    /// containing only the provided pure value.
    ///
    /// # Arguments
    ///
    /// *   `value`: The pure value to lift.
    ///
    /// # Returns
    ///
    /// An effectful value of type `E::HktWitness::Type<T>`.
    #[allow(clippy::type_complexity)]
    fn pure<T>(
        value: T,
    ) -> <E::HktWitness as HKT5<E::Fixed1, E::Fixed2, E::Fixed3, E::Fixed4>>::Type<T>;

    /// The core sequencing operation for arity 5 effect systems.
    ///
    /// This method chains a computation `f` to an existing effectful value `effect`.
    /// If `effect` contains an error, the error is propagated. Otherwise, the function `f`
    /// is applied to the value within `effect`, and any logs/counters/traces are combined.
    ///
    /// # Arguments
    ///
    /// *   `effect`: The initial effectful value.
    /// *   `f`: A function that takes the inner value of `effect` and returns a new effectful value.
    ///
    /// # Returns
    ///
    /// A new effectful value representing the chained computation.
    ///
    /// # Type Parameters
    ///
    /// *   `T`: The type of the value inside the initial effect.
    /// *   `U`: The type of the value inside the resulting effect.
    /// *   `Func`: The type of the binding function.
    #[allow(clippy::type_complexity)]
    fn bind<T, U, Func>(
        effect: <E::HktWitness as HKT5<E::Fixed1, E::Fixed2, E::Fixed3, E::Fixed4>>::Type<T>,
        f: Func,
    ) -> <E::HktWitness as HKT5<E::Fixed1, E::Fixed2, E::Fixed3, E::Fixed4>>::Type<U>
    where
        Func: FnMut(
            T,
        )
            -> <E::HktWitness as HKT5<E::Fixed1, E::Fixed2, E::Fixed3, E::Fixed4>>::Type<U>,
        U: Default;
}
