/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tier 2 witness-typed isomorphism traits.
//!
//! This module hosts the [`Iso<S, T>`] trait — a witness-typed isomorphism
//! with explicit `to_target` / `to_source` methods — and its
//! structure-preserving marker subtraits ([`GroupIso<S, T>`],
//! [`RingIso<S, T>`], [`FieldIso<S, T>`], [`AlgebraIso<S, T, R>`],
//! [`DivisionAlgebraIso<S, T, R>`]).
//!
//! Tier 2 is used when bidirectional `From` cannot be implemented because
//! source and target live in different crates with an asymmetric dependency
//! (the common case for cross-crate isos). The impl is hung on whichever of
//! `S` or `T` is local to the crate writing the impl.
//!
//! For in-crate isos where bidirectional `From` is implementable, **prefer
//! Tier 1** ([`crate::iso`]) — the marker subtraits there are bounded on
//! `From`/`Into` directly and require no new trait surface.
//!
//! # `StandardIso<S, T>` default witness
//!
//! [`StandardIso<S, T>`] is a generic zero-sized witness with blanket impls
//! covering [`Iso<S, T>`] and every Tier 2 marker subtrait. The blanket impls
//! fire automatically when `S` and `T` satisfy bidirectional `From` plus the
//! relevant algebraic-structure trait — no manual marker impl required for
//! the common case.
//!
//! # Namespace
//!
//! Tier 1 (`crate::iso::*`) and Tier 2 (`crate::iso::witness::*`) marker
//! subtraits share short names (`GroupIso`, `RingIso`, etc.). Disambiguate by
//! module path:
//!
//! ```ignore
//! use deep_causality_algebra::iso::GroupIso;            // Tier 1 (one parameter)
//! use deep_causality_algebra::iso::witness::GroupIso;   // Tier 2 (two parameters)
//! ```

pub mod algebra_iso;
pub mod division_algebra_iso;
pub mod field_iso;
pub mod group_iso;
pub mod iso;
pub mod ring_iso;
pub mod standard;
pub mod test_support;

pub use algebra_iso::AlgebraIso;
pub use division_algebra_iso::DivisionAlgebraIso;
pub use field_iso::FieldIso;
pub use group_iso::GroupIso;
pub use iso::Iso;
pub use ring_iso::RingIso;
pub use standard::StandardIso;
