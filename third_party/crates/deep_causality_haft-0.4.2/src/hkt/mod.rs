/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Core Higher-Kinded Type (HKT) Machinery.
//!
//! This module provides the foundational traits and types required to emulate Higher-Kinded Types (HKTs)
//! in Rust, a language that does not natively support them. It uses the "Generic Associated Types (GAT) Pattern"
//! to achieve this.
//!
//! # The Problem: Missing HKTs in Rust
//!
//! In languages like Haskell, you can write a trait (typeclass) that is generic over a type constructor `F<_>`:
//!
//! ```haskell
//! class Functor f where
//!   fmap :: (a -> b) -> f a -> f b
//! ```
//!
//! In Rust, generic parameters must be concrete types (of kind `*`), not type constructors (of kind `* -> *`).
//! You cannot write `trait Functor<F<A>>`.
//!
//! # The Solution: The GAT Pattern
//!
//! We define a "Witness" trait (`HKT`) that acts as a proxy for the type constructor. This witness trait
//! contains a Generic Associated Type (GAT) `Type<T>` which projects the witness back to the concrete type.
//!
//! ```rust,ignore
//! pub trait HKT {
//!     type Type<T>; // The GAT
//! }
//!
//! struct OptionWitness; // The Witness
//! impl HKT for OptionWitness {
//!     type Type<T> = Option<T>; // The Projection
//! }
//! ```
//!
//! This allows us to write generic traits like `Functor` over the witness `F`:
//!
//! ```rust,ignore
//! trait Functor<F: HKT> {
//!     fn fmap<A, B>(fa: F::Type<A>, f: Fn(A) -> B) -> F::Type<B>;
//! }
//! ```
//!
//! # Module Contents
//!
//! *   [`hkt`]: Defines the standard `HKT` trait (Arity 1) and fixed-parameter HKTs (`HKT2`, `HKT3`, etc.)
//!     where all but one parameter are fixed.
//! *   [`hkt_unbound`]: Defines "Unbound" HKT traits (`HKT2Unbound`, `HKT3Unbound`, etc.) where
//!     multiple parameters remain generic. This corresponds to multi-parameter type constructors
//!     like `Result<E, T>` (Bifunctor) or `(A, B, C)` (Trifunctor).
//!
//! # Arity Support
//!
//! This crate supports HKTs up to Arity 6 (for complex effect systems).
//!
//! *   **Arity 1**: `HKT` (e.g., `Option<T>`, `Vec<T>`)
//! *   **Arity 2**: `HKT2` (Fixed), `HKT2Unbound` (e.g., `Result<E, T>`)
//! *   **Arity 3**: `HKT3` (Fixed), `HKT3Unbound` (e.g., `(A, B, C)`)
//! *   **Arity 4**: `HKT4` (Fixed), `HKT4Unbound`
//! *   **Arity 5**: `HKT5` (Fixed), `HKT5Unbound`
//! *   **Arity 6**: `HKT6Unbound`

/// Marker trait indicating that type `T` satisfies constraint `C`.
///
/// This is the core abstraction that enables type-safe constraint checking
/// at compile time. Constraints are implemented as marker structs, and
/// blanket implementations of `Satisfies` define which types satisfy each constraint.
///
/// # Design Philosophy
///
/// The `?Sized` bound on `C` allows for flexibility in constraint definitions,
/// including trait objects if needed in the future.
///
/// # Safety
///
/// This trait is a pure marker and has no methods. Implementations should
/// not have any runtime behavior.
pub trait Satisfies<C: ?Sized> {}

/// The universal constraint — every type satisfies it.
///
/// Use this constraint for fully polymorphic HKT implementations like
/// `Vec`, `Option`, `Box`, etc., where no specific bounds are required
/// on the inner type.
///
/// # Example
///
/// ```rust
/// use deep_causality_haft::{Satisfies, NoConstraint};
///
/// // This blanket impl means String, Vec<u8>, custom types, etc. all satisfy NoConstraint
/// fn accepts_any<T: Satisfies<NoConstraint>>(_: T) {}
///
/// accepts_any("hello");
/// accepts_any(42);
/// accepts_any(vec![1, 2, 3]);
/// ```
pub struct NoConstraint;

impl<T> Satisfies<NoConstraint> for T {}

// ----------------------------------------------------
// Higher Kinded Types (HKT) Traits for Arity 1 - 5
// ----------------------------------------------------

/// A zero-sized type used purely as a marker or placeholder when implementing
/// Higher-Kinded Type (HKT) traits for concrete types.
///
/// This struct is essential for the "witness" pattern, where a concrete type
/// (like `Option<T>`) cannot directly implement an HKT trait due to Rust's
/// type system limitations. Instead, a `Witness` type (e.g., `OptionWitness`)
/// implements the HKT trait, using `Placeholder` to represent the generic
/// parameters that are being abstracted over.
///
/// # Examples
///
/// ```
/// use deep_causality_haft::{NoConstraint, HKT, Placeholder};
///
/// // A witness for Option<T>
/// pub struct OptionWitness;
///
/// impl HKT for OptionWitness {
///     type Constraint = NoConstraint;
///     type Type<T> = Option<T>;
/// }
///
/// let my_option: <OptionWitness as HKT>::Type<i32> = Some(10);
/// assert_eq!(my_option, Some(10));
/// ```
pub struct Placeholder;

/// Trait for a Higher-Kinded Type (HKT) with one type parameter (arity 1).
///
/// This trait is implemented by a concrete "witness" type (e.g., `OptionWitness`)
/// which serves as a token to refer to a type constructor (e.g., `Option<T>`).
/// The `Type<T>` associated type defines the actual type constructor, with `<T>`
/// representing the single generic parameter that can vary.
///
/// # Unified Constraint System
///
/// The `Constraint` associated type declares what bounds the inner type `T` must satisfy
/// when using functional operations like `fmap`, `bind`, etc. This enables a **single
/// trait hierarchy** for both constrained and unconstrained types:
///
/// - **Unconstrained types** (like `Vec<T>`) use `type Constraint = NoConstraint;`
/// - **Constrained types** (like `CausalTensor<T>`) use `type Constraint = TensorDataConstraint;`
///
/// Note: The constraint is enforced at the trait method level (Functor, Monad, etc.),
/// not at the `Type<T>` GAT level. This allows the GAT to be used with any type,
/// while the functional operations validate the constraints.
///
/// # For Unconstrained Types
///
/// ```rust
/// use deep_causality_haft::{HKT, NoConstraint};
///
/// pub struct VecWitness;
///
/// impl HKT for VecWitness {
///     type Constraint = NoConstraint;
///     type Type<T> = Vec<T>;
/// }
/// ```
///
/// # For Constrained Types
///
/// ```rust,ignore
/// impl HKT for CausalTensorWitness {
///     type Constraint = TensorDataConstraint;
///     type Type<T> = CausalTensor<T>;
/// }
/// ```
///
/// # Type Parameters
///
/// *   `T`: The generic type parameter that the type constructor operates on.
pub trait HKT {
    /// The constraint on inner types. Use `NoConstraint` for fully polymorphic.
    type Constraint: ?Sized;

    /// The Generic Associated Type (GAT) that represents the type constructor.
    /// The `<T>` is the "hole" in the type constructor (e.g., `Option<T>`).
    ///
    /// The where clause ensures constraint propagation at the type level,
    /// enabling types with inherent bounds (like `CausalMultiField`) to
    /// participate in the unified HKT system.
    type Type<T>
    where
        T: Satisfies<Self::Constraint>;
}

// ----------------------------------------------------
// HKT Trait for Arity 2: Kind *, * -> *
// ----------------------------------------------------

/// Trait for a Higher-Kinded Type (HKT) with two type parameters (arity 2).
///
/// This trait is generic over the first type parameter to be "fixed" (`F`).
/// This allows the trait to represent a type constructor that is partially applied,
/// leaving one generic parameter (`T`) open.
///
/// # Purpose
///
/// Useful for type constructors like `Result<T, E>` where `E` (the error type)
/// can be fixed, allowing the `Result` to behave like an arity-1 HKT over `T`.
/// This is crucial for integrating such types into functional programming patterns
/// where only one type parameter is expected to vary.
///
/// # Type Parameters
///
/// *   `F`: The first generic type parameter that is fixed by the implementing witness.
/// *   `T`: The remaining generic type parameter that the type constructor operates on.
///
/// # Examples
///
/// ```
/// use deep_causality_haft::{HKT2, Placeholder};
///
/// // A witness for Result<T, E> where E is fixed
/// pub struct ResultWitness<E>(Placeholder, E);
///
/// impl<E> HKT2<E> for ResultWitness<E> {
///     type Type<T> = Result<T, E>;
/// }
///
/// type MyResult<T> = <ResultWitness<String> as HKT2<String>>::Type<T>;
/// let ok_value: MyResult<i32> = Ok(20);
/// assert_eq!(ok_value, Ok(20));
/// ```
pub trait HKT2<F> {
    /// The GAT that represents the remaining type constructor.
    /// The resulting kind is `* -> *` (one hole `<T>` remaining).
    ///
    /// Example: If the implementing type is `Result<(), F>` and `F` is `i32`,
    /// then `Type<T>` is `Result<T, i32>`.
    type Type<T>;
}

// ----------------------------------------------------
// HKT Trait for Arity 3: Kind *, *, * -> *
// ----------------------------------------------------

/// Trait for a Higher-Kinded Type (HKT) with three type parameters (arity 3).
///
/// This trait is generic over the first two type parameters to be "fixed" (`F1` and `F2`).
/// This allows the trait to represent a type constructor that is partially applied,
/// leaving one generic parameter (`T`) open.
///
/// # Purpose
///
/// Essential for building type-encoded effect systems where two specific effect types
/// (e.g., Error and Warning/Log) are fixed, and the primary value type `T` remains generic.
/// This enables explicit tracking of multiple side-effects within a single type.
///
/// # Type Parameters
///
/// *   `F1`: The first generic type parameter that is fixed (e.g., an Error type).
/// *   `F2`: The second generic type parameter that is fixed (e.g., a Warning/Log type).
/// *   `T`: The remaining generic type parameter that the type constructor operates on.
///
/// # Examples
///
/// ```
/// use deep_causality_haft::{HKT3, Placeholder};
///
/// // A dummy type with three generic parameters
/// struct MyCustomType<T, F1, F2> { value: T, _f1: F1, _f2: F2, }
///
/// // Witness for MyCustomType<T, F1, F2> where F1 and F2 are fixed
/// struct MyCustomTypeWitness<F1, F2>(Placeholder, F1, F2);
///
/// impl<F1, F2> HKT3<F1, F2> for MyCustomTypeWitness<F1, F2> {
///     type Type<T> = MyCustomType<T, F1, F2>;
/// }
///
/// type MyHkt3Type<T> = <MyCustomTypeWitness<String, u32> as HKT3<String, u32>>::Type<T>;
/// let instance = MyHkt3Type {
///     value: 30,
///     _f1: "Fixed String".to_string(),
///     _f2: 100u32,
/// };
/// assert_eq!(instance.value, 30);
/// ```
pub trait HKT3<F1, F2> {
    /// The GAT that represents the remaining type constructor.
    /// The resulting kind is `* -> *` (one hole `<T>` remaining).
    ///
    /// Example: If the implementing type is `DiscoveryResult<(), F1, F2>`,
    /// then `Type<T>` is `DiscoveryResult<T, F1, F2>`.
    type Type<T>;
}

// ----------------------------------------------------
// HKT Trait for Arity 4: Kind *, *, *, * -> *
// ----------------------------------------------------

/// Trait for a Higher-Kinded Type (HKT) with four type parameters (arity 4).
///
/// This trait is generic over the first three type parameters to be "fixed" (`F1`, `F2`, `F3`).
/// This allows the trait to represent a type constructor that is partially applied,
/// leaving one generic parameter (`T`) open.
///
/// # Purpose
///
/// Extends the concept of `HKT3` to include a third fixed effect type.
/// This is useful for more complex effect systems that need to track three distinct
/// side-effects (e.g., Error, Warning, and a Counter) alongside the primary value type.
///
/// # Type Parameters
///
/// *   `F1`: The first generic type parameter that is fixed.
/// *   `F2`: The second generic type parameter that is fixed.
/// *   `F3`: The third generic type parameter that is fixed.
/// *   `T`: The remaining generic type parameter that the type constructor operates on.
///
/// # Examples
///
/// ```
/// use deep_causality_haft::{HKT4, Placeholder};
///
/// // A dummy type with four generic parameters
/// struct MyCustomType4<T, F1, F2, F3> { value: T, _f1: F1, _f2: F2, _f3: F3, }
///
/// // Witness for MyCustomType4<T, F1, F2, F3> where F1, F2, and F3 are fixed
/// struct MyCustomTypeWitness4<F1, F2, F3>(Placeholder, F1, F2, F3);
///
/// impl<F1, F2, F3> HKT4<F1, F2, F3> for MyCustomTypeWitness4<F1, F2, F3> {
///     type Type<T> = MyCustomType4<T, F1, F2, F3>;
/// }
///
/// type MyHkt4Type<T> =
///     <MyCustomTypeWitness4<String, u32, bool> as HKT4<String, u32, bool>>::Type<T>;
///
/// let instance = MyHkt4Type {
///     value: 40,
///     _f1: "Fixed String".to_string(),
///     _f2: 200u32,
///     _f3: true,
/// };
/// assert_eq!(instance.value, 40);
/// ```
pub trait HKT4<F1, F2, F3> {
    /// The GAT that represents the remaining type constructor.
    /// The resulting kind is `* -> *` (one hole `<T>` remaining).
    type Type<T>;
}

// ----------------------------------------------------
// HKT Trait for Arity 5: Kind *, *, *, *, * -> *
// ----------------------------------------------------

/// Trait for a Higher-Kinded Type (HKT) with five type parameters (arity 5).
///
/// This trait is generic over the first four type parameters to be "fixed" (`F1`, `F2`, `F3`, `F4`).
/// This allows the trait to represent a type constructor that is partially applied,
/// leaving one generic parameter (`T`) open.
///
/// # Purpose
///
/// Provides the highest arity HKT trait for highly expressive type-encoded effect systems.
/// It enables tracking four distinct side-effects (e.g., Error, Warning, Counter, and Trace)
/// alongside the primary value type, offering fine-grained control over computational effects.
///
/// # Type Parameters
///
/// *   `F1`: The first generic type parameter that is fixed.
/// *   `F2`: The second generic type parameter that is fixed.
/// *   `F3`: The third generic type parameter that is fixed.
/// *   `F4`: The fourth generic type parameter that is fixed.
/// *   `T`: The remaining generic type parameter that the type constructor operates on.
///
/// # Examples
///
/// ```
/// use deep_causality_haft::{HKT5, Placeholder};
///
/// // A dummy type with five generic parameters
/// struct MyCustomType5<T, F1, F2, F3, F4> { value: T, _f1: F1, _f2: F2, _f3: F3, _f4: F4, }
///
/// // Witness for MyCustomType5<T, F1, F2, F3, F4> where F1, F2, F3, and F4 are fixed
/// struct MyCustomTypeWitness5<F1, F2, F3, F4>(Placeholder, F1, F2, F3, F4);
///
/// impl<F1, F2, F3, F4> HKT5<F1, F2, F3, F4> for MyCustomTypeWitness5<F1, F2, F3, F4> {
///     type Type<T> = MyCustomType5<T, F1, F2, F3, F4>;
/// }
///
/// type MyHkt5Type<T> =
///     <MyCustomTypeWitness5<String, u32, bool, f64> as HKT5<String, u32, bool, f64>>::Type<T>;
///
/// let instance = MyHkt5Type {
///     value: 50,
///     _f1: "Fixed String".to_string(),
///     _f2: 300u32,
///     _f3: false,
///     _f4: 1.23,
/// };
/// assert_eq!(instance.value, 50);
/// ```
pub trait HKT5<F1, F2, F3, F4> {
    /// The GAT that represents the remaining type constructor.
    /// The resulting kind is `* -> *` (one hole `<T>` remaining).
    type Type<T>;
}

// ----------------------------------------------------
// Unbound Higher Kinded Types (HKT) Traits for Arity 2 - 5
// ----------------------------------------------------

/// Trait for a Higher-Kinded Type (HKT) with two unbound generic parameters (Arity 2).
///
/// Unlike `HKT2`, which fixes one parameter and leaves one free (`F<T>`),
/// `HKT2Unbound` leaves *both* parameters free (`F<A, B>`).
///
/// # Category Theory
/// Corresponds to a **Bifunctor** or a type constructor $F: \mathcal{C} \times \mathcal{D} \to \mathcal{E}$.
/// It maps a pair of objects $(A, B)$ to a new object $F(A, B)$.
///
/// # Examples
/// * `Result<A, B>`
/// * `(A, B)` (Tuple)
/// * `Either<A, B>`
pub trait HKT2Unbound {
    type Constraint: ?Sized;
    /// The Generic Associated Type representing F<A, B>
    type Type<A, B>
    where
        A: Satisfies<Self::Constraint>,
        B: Satisfies<Self::Constraint>;
}

/// Trait for a Higher-Kinded Type (HKT) with three generic parameters (Arity 3).
///
/// # Category Theory
/// Corresponds to a **Trifunctor** or a type constructor $F: \mathcal{C} \times \mathcal{D} \times \mathcal{E} \to \mathcal{S}$.
///
/// # Examples
/// * `(A, B, C)` (Triple)
/// * `State<S_in, S_out, A>` (Parametric State)
pub trait HKT3Unbound {
    type Constraint: ?Sized;
    type Type<A, B, C>
    where
        A: Satisfies<Self::Constraint>,
        B: Satisfies<Self::Constraint>,
        C: Satisfies<Self::Constraint>;
}

/// Trait for a Higher-Kinded Type (HKT) with four generic parameters (Arity 4).
///
/// # Category Theory
/// Corresponds to a **Quadrifunctor** or a generic tensor of rank 4.
///
/// # Examples
/// * `(A, B, C, D)` (Quadruple)
/// * `RiemannTensor<A, B, C, D>`
pub trait HKT4Unbound {
    type Constraint: ?Sized;
    type Type<A, B, C, D>
    where
        A: Satisfies<Self::Constraint>,
        B: Satisfies<Self::Constraint>,
        C: Satisfies<Self::Constraint>,
        D: Satisfies<Self::Constraint>;
}

/// Trait for a Higher-Kinded Type (HKT) with five generic parameters (Arity 5).
///
/// # Category Theory
/// Corresponds to a **Pentafunctor**.
///
/// # Examples
/// * `(A, B, C, D, E)` (Quintuple)
/// * `CyberneticLoop<S, B, C, A, E>`
pub trait HKT5Unbound {
    type Constraint: ?Sized;
    type Type<A, B, C, D, E>
    where
        A: Satisfies<Self::Constraint>,
        B: Satisfies<Self::Constraint>,
        C: Satisfies<Self::Constraint>,
        D: Satisfies<Self::Constraint>,
        E: Satisfies<Self::Constraint>;
}

/// Trait for a Higher-Kinded Type (HKT) with six generic parameters (Arity 6).
///
/// # Category Theory
/// Corresponds to a **Hexafunctor**.
///
/// # Examples
/// * `(A, B, C, D, E, F)` (Sextuple)
/// * `Effect5Unbound<Fixed1, Fixed2, Fixed3, S_in, S_out, A>`
pub trait HKT6Unbound {
    type Constraint: ?Sized;
    type Type<A, B, C, D, E, F>
    where
        A: Satisfies<Self::Constraint>,
        B: Satisfies<Self::Constraint>,
        C: Satisfies<Self::Constraint>,
        D: Satisfies<Self::Constraint>,
        E: Satisfies<Self::Constraint>,
        F: Satisfies<Self::Constraint>;
}
