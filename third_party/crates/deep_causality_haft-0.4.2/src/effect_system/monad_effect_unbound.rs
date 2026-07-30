/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{
    Effect3Unbound, Effect4Unbound, Effect5Unbound, HKT4Unbound, HKT5Unbound, HKT6Unbound,
    Satisfies,
};

// ----------------------------------------------------
// Unbound Monad Effect Traits (Parametric Effects | Arity 3)
// ----------------------------------------------------

/// Monadic logic for Parametric Effects (Arity 3 Unbound).
///
/// Enables state transitions (`S1 -> S2`) within the effect system.
pub trait MonadEffect3Unbound<E: Effect3Unbound> {
    /// Lifts a pure value into the parametric effect container.
    /// The state `S` remains unchanged (`S -> S`).
    fn pure<S, T>(value: T) -> <E::HktWitness as HKT4Unbound>::Type<E::Fixed1, S, S, T>
    where
        S: Satisfies<<E::HktWitness as HKT4Unbound>::Constraint>,
        T: Satisfies<<E::HktWitness as HKT4Unbound>::Constraint>,
        E::Fixed1: Satisfies<<E::HktWitness as HKT4Unbound>::Constraint>;

    /// Indexed Bind: Chains computations while tracking state transitions.
    /// `S1 -> S2` (first step) AND `S2 -> S3` (second step) => `S1 -> S3` (result).
    fn ibind<S1, S2, S3, T, U, Func>(
        effect: <E::HktWitness as HKT4Unbound>::Type<E::Fixed1, S1, S2, T>,
        f: Func,
    ) -> <E::HktWitness as HKT4Unbound>::Type<E::Fixed1, S1, S3, U>
    where
        S1: Satisfies<<E::HktWitness as HKT4Unbound>::Constraint>,
        S2: Satisfies<<E::HktWitness as HKT4Unbound>::Constraint>,
        S3: Satisfies<<E::HktWitness as HKT4Unbound>::Constraint>,
        T: Satisfies<<E::HktWitness as HKT4Unbound>::Constraint>,
        U: Satisfies<<E::HktWitness as HKT4Unbound>::Constraint>,
        E::Fixed1: Satisfies<<E::HktWitness as HKT4Unbound>::Constraint>,
        Func: FnMut(T) -> <E::HktWitness as HKT4Unbound>::Type<E::Fixed1, S2, S3, U>;
}

// ----------------------------------------------------
// Unbound Monad Effect Traits (Parametric Effects | Arity 4)
// ----------------------------------------------------

/// Monadic logic for Parametric Effects (Arity 4 Unbound).
///
/// Enables state transitions (`S1 -> S2`) within the effect system.
#[allow(clippy::type_complexity)]
pub trait MonadEffect4Unbound<E: Effect4Unbound> {
    /// Lifts a pure value into the parametric effect container.
    /// The state `S` remains unchanged (`S -> S`).
    fn pure<S, T>(value: T) -> <E::HktWitness as HKT5Unbound>::Type<E::Fixed1, E::Fixed2, S, S, T>
    where
        S: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        T: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        E::Fixed1: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        E::Fixed2: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>;

    /// Indexed Bind: Chains computations while tracking state transitions.
    fn ibind<S1, S2, S3, T, U, Func>(
        effect: <E::HktWitness as HKT5Unbound>::Type<E::Fixed1, E::Fixed2, S1, S2, T>,
        f: Func,
    ) -> <E::HktWitness as HKT5Unbound>::Type<E::Fixed1, E::Fixed2, S1, S3, U>
    where
        S1: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        S2: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        S3: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        T: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        U: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        E::Fixed1: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        E::Fixed2: Satisfies<<E::HktWitness as HKT5Unbound>::Constraint>,
        Func: FnMut(T) -> <E::HktWitness as HKT5Unbound>::Type<E::Fixed1, E::Fixed2, S2, S3, U>;
}

// ----------------------------------------------------
// Unbound Monad Effect Traits (Parametric Effects | Arity 5)
// ----------------------------------------------------

/// Monadic logic for Parametric Effects (Arity 5 Unbound).
///
/// Enables state transitions (`S1 -> S2`) within the effect system.
#[allow(clippy::type_complexity)]
pub trait MonadEffect5Unbound<E: Effect5Unbound> {
    /// Lifts a pure value into the parametric effect container.
    /// The state `S` remains unchanged (`S -> S`).
    fn pure<S, T>(
        value: T,
    ) -> <E::HktWitness as HKT6Unbound>::Type<E::Fixed1, E::Fixed2, E::Fixed3, S, S, T>
    where
        S: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        T: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        E::Fixed1: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        E::Fixed2: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        E::Fixed3: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>;

    /// Indexed Bind: Chains computations while tracking state transitions.
    fn ibind<S1, S2, S3, T, U, Func>(
        effect: <E::HktWitness as HKT6Unbound>::Type<E::Fixed1, E::Fixed2, E::Fixed3, S1, S2, T>,
        f: Func,
    ) -> <E::HktWitness as HKT6Unbound>::Type<E::Fixed1, E::Fixed2, E::Fixed3, S1, S3, U>
    where
        S1: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        S2: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        S3: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        T: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        U: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        E::Fixed1: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        E::Fixed2: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        E::Fixed3: Satisfies<<E::HktWitness as HKT6Unbound>::Constraint>,
        Func: FnMut(
            T,
        ) -> <E::HktWitness as HKT6Unbound>::Type<
            E::Fixed1,
            E::Fixed2,
            E::Fixed3,
            S2,
            S3,
            U,
        >;
}
