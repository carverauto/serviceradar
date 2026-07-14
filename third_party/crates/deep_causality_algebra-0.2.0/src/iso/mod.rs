/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tier 1 structure-preserving isomorphism marker subtraits.
//!
//! This module exposes a family of empty marker traits that ride on top of
//! Rust's standard `From` / `Into` conversion machinery. Implementing a marker
//! is a type-level promise that the bidirectional `From` impls between `Self`
//! and `T` preserve the corresponding algebraic structure — additive group,
//! ring, field, algebra-over-ring, or division algebra.
//!
//! # The Tier 1 / Tier 2 / Tier 3 design
//!
//! - **Tier 1 (this module)** — for in-crate isomorphisms where bidirectional
//!   `From` can be implemented without orphan-rule violations. Marker subtraits
//!   bound on `From<T>` + `From<Self>` plus the corresponding algebraic-structure
//!   trait. The trait body is empty; laws are verified by property tests in
//!   [`test_support`].
//! - **Tier 2 (forward-looking)** — for cross-crate isomorphisms blocked by
//!   the orphan rule. Introduces a witness-typed `Iso<S, T>` trait with explicit
//!   `to_target` / `to_source` methods, plus a `StandardIso<S, T>` generic
//!   witness with blanket impls that auto-derive every marker from bidirectional
//!   `From`. Will be added in a follow-up change.
//! - **Tier 3 (in `deep_causality_haft`)** — `NaturalIso<F, G>` for HKT
//!   witnesses, which are zero-sized types with no instances to convert. Bridges
//!   the gap that Tier 1 / Tier 2 cannot cover.
//!
//! # Hierarchy
//!
//! Inheritance chain (most general at the top):
//!
//! ```text
//! GroupIso<T>             (additive group homomorphism)
//!   ↑
//! RingIso<T>              (+ multiplicative homomorphism)
//!   ↑
//! FieldIso<T>             (+ multiplicative inverse preservation)
//!
//! AlgebraIso<T, R>        (scalar multiplication preservation)
//!   ↑
//! DivisionAlgebraIso<T, R> (+ conjugation preservation)
//! ```
//!
//! Vector-structure markers (`AlgebraIso`, `DivisionAlgebraIso`) are parallel
//! to the additive/multiplicative chain rather than extending it; implementers
//! that satisfy both algebraic structures write the marker impls separately.
//!
//! # No type-system enforcement
//!
//! Rust cannot prove the homomorphism laws structurally. The markers are
//! reviewer-visible contracts; the laws are verified by property tests using
//! the helpers in [`test_support`]. CI enforces test-coverage discipline by
//! code review.
//!
//! # Example
//!
//! ```ignore
//! use deep_causality_algebra::iso::{GroupIso, RingIso};
//!
//! // Assuming both From<Other> for MyType and From<MyType> for Other exist:
//! impl GroupIso<Other> for MyType {}
//! impl RingIso<Other> for MyType {}
//! ```

pub mod algebra_iso;
pub mod division_algebra_iso;
pub mod field_iso;
pub mod group_iso;
pub mod ring_iso;
pub mod test_support;
pub mod witness;

pub use algebra_iso::AlgebraIso;
pub use division_algebra_iso::DivisionAlgebraIso;
pub use field_iso::FieldIso;
pub use group_iso::GroupIso;
pub use ring_iso::RingIso;

// Tier 2 (witness-typed) traits are NOT re-exported at the top-level `iso::`
// path because they share short names with the Tier 1 subtraits. Consumers
// disambiguate via the module path: `iso::witness::GroupIso<S, T>` vs the
// Tier 1 `iso::GroupIso<T>`.
