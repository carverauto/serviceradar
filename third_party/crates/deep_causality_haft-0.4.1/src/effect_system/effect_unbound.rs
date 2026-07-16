/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// ----------------------------------------------------
// Unbound Effect Traits (Parametric Effects | Arity 3)
// ----------------------------------------------------

use crate::{HKT4Unbound, HKT5Unbound, HKT6Unbound};

/// Effect3Unbound: Parametric Effect Trait for Arity 3.
///
/// This trait allows for **Parametric Effects** (Type-State Pattern) where one effect component
/// (the State/Counter) can change its type during computation.
///
/// It fixes 1 parameter (e.g., Error) and leaves 2 parameters for the State transition (`S_in`, `S_out`),
/// plus the Value type `A`. This requires an Arity 4 witness (`HKT4Unbound`).
///
/// Structure: `Type<Fixed1, S_in, S_out, A>`
pub trait Effect3Unbound {
    /// The fixed type (e.g., Error).
    type Fixed1;

    /// The witness type implementing `HKT4Unbound`.
    type HktWitness: HKT4Unbound;
}

// ----------------------------------------------------
// Unbound Effect Traits (Parametric Effects | Arity 4)
// ----------------------------------------------------

/// Effect4Unbound: Parametric Effect Trait for Arity 4.
///
/// This trait allows for **Parametric Effects** where one effect component
/// (the State/Counter) can change its type, while two others (e.g., Error, Log) remain fixed.
///
/// Structure: `Type<Fixed1, Fixed2, S_in, S_out, A>`
/// This requires an Arity 5 witness (`HKT5Unbound`).
pub trait Effect4Unbound {
    /// The first fixed type (e.g., Error).
    type Fixed1;

    /// The second fixed type (e.g., Log).
    type Fixed2;

    /// The witness type implementing `HKT5Unbound`.
    type HktWitness: HKT5Unbound;
}

// ----------------------------------------------------
// Unbound Effect Traits (Parametric Effects | Arity 5)
// ----------------------------------------------------

/// Effect5Unbound: Parametric Effect Trait for Arity 5.
///
/// This trait allows for **Parametric Effects** where one effect component
/// (the State/Counter) can change its type, while three others (e.g., Error, Log, Trace) remain fixed.
///
/// Structure: `Type<Fixed1, Fixed2, Fixed3, S_in, S_out, A>`
/// This requires an Arity 6 witness (`HKT6Unbound`).
pub trait Effect5Unbound {
    /// The first fixed type (e.g., Error).
    type Fixed1;

    /// The second fixed type (e.g., Log).
    type Fixed2;

    /// The third fixed type (e.g., Trace).
    type Fixed3;

    /// The witness type implementing `HKT6Unbound`.
    type HktWitness: HKT6Unbound;
}
