/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// ----------------------------------------------------
// Effect Traits (Arity 3)
// ----------------------------------------------------

use crate::{HKT, HKT3, HKT4, HKT5};

/// Effect3: The Bridge Trait for Arity 3 Type Constructors.
///
/// This trait is implemented by a user-defined **System Witness** (e.g., `MyEffect`)
/// to partially apply (fix) two of the three generic parameters of an `HKT3` type.
/// It serves as a crucial component in building type-encoded effect systems,
/// allowing for the explicit tracking and handling of two fixed effect types
/// (e.g., Error and Warning) while keeping the primary value type generic.
pub trait Effect3 {
    /// The fixed type for the first parameter of the `HKT3` type.
    /// In many effect systems, this represents the Error type (e.g., `String`, `MyErrorStruct`).
    type Fixed1;

    /// The fixed type for the second parameter of the `HKT3` type.
    /// This often represents a Warning or Log type (e.g., `String`, `Vec<String>`).
    type Fixed2;

    /// The concrete witness type that implements `HKT3` with the two fixed types (`Fixed1`, `Fixed2`).
    /// This witness type *MUST* also implement `HKT` to be compatible with `Functor` and `Monad` traits.
    /// It acts as a token to refer to the partially applied type constructor.
    type HktWitness: HKT3<Self::Fixed1, Self::Fixed2> + HKT;
}

// ----------------------------------------------------
// Effect Traits (Arity 4)
// ----------------------------------------------------

/// Effect4: The Bridge Trait for Arity 4 Type Constructors.
///
/// Similar to `Effect3`, this trait is implemented by a user-defined **System Witness**
/// to partially apply (fix) three of the four generic parameters of an `HKT4` type.
/// It is used for effect systems that need to track three distinct fixed effect types
/// (e.g., Error, Warning, and a Counter) alongside the primary value type.
pub trait Effect4 {
    /// The fixed type for the first parameter of the `HKT4` type (e.g., an Error type).
    type Fixed1;

    /// The fixed type for the second parameter of the `HKT4` type (e.g., a Log type).
    type Fixed2;

    /// The fixed type for the third parameter of the `HKT4` type (e.g., a Counter type).
    type Fixed3;

    /// The concrete witness type that implements `HKT4` with the three fixed types (`Fixed1`, `Fixed2`, `Fixed3`).
    /// This witness type *MUST* also implement `HKT` to be compatible with `Functor` and `Monad` traits.
    type HktWitness: HKT4<Self::Fixed1, Self::Fixed2, Self::Fixed3> + HKT;
}

// ----------------------------------------------------
// Effect Traits (Arity 5)
// ----------------------------------------------------

/// Effect5: The Bridge Trait for Arity 5 Type Constructors.
///
/// This trait is implemented by a user-defined **System Witness**
/// to partially apply (fix) four of the five generic parameters of an `HKT5` type.
/// It is designed for highly expressive effect systems that need to track four distinct fixed effect types
/// (e.g., Error, Warning, Counter, and Trace information) alongside the primary value type.
pub trait Effect5 {
    /// The fixed type for the first parameter of the `HKT5` type (e.g., an Error type).
    type Fixed1;

    /// The fixed type for the second parameter of the `HKT5` type (e.g., a Log type).
    type Fixed2;

    /// The fixed type for the third parameter of the `HKT5` type (e.g., a Counter type).
    type Fixed3;

    /// The fixed type for the fourth parameter of the `HKT5` type (e.g., a Trace type).
    type Fixed4;

    /// The concrete witness type that implements `HKT5` with the four fixed types (`Fixed1`, `Fixed2`, `Fixed3`, `Fixed4`).
    /// This witness type *MUST* also implement `HKT` to be compatible with `Functor` and `Monad` traits.
    type HktWitness: HKT5<Self::Fixed1, Self::Fixed2, Self::Fixed3, Self::Fixed4> + HKT;
}
