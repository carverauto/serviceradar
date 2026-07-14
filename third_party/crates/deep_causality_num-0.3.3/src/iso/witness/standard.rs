/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use core::fmt;
use core::marker::PhantomData;

use crate::iso::witness::algebra_iso::AlgebraIso;
use crate::iso::witness::division_algebra_iso::DivisionAlgebraIso;
use crate::iso::witness::field_iso::FieldIso;
use crate::iso::witness::group_iso::GroupIso;
use crate::iso::witness::iso::Iso;
use crate::iso::witness::ring_iso::RingIso;
use crate::{Algebra, DivisionAlgebra, Field, Group, Ring};

/// Generic default witness for Tier 2 isomorphisms that ride on bidirectional
/// `From` impls.
///
/// `StandardIso<S, T>` is a zero-sized type carrying no runtime data. Its
/// purpose is to host **blanket impls** of [`Iso<S, T>`] and every Tier 2
/// marker subtrait: when the underlying types `S` and `T` already satisfy
/// bidirectional `From` plus the relevant algebraic-structure trait, the
/// blanket impl fires automatically and no manual marker `impl` block is
/// required.
///
/// # The blanket pattern
///
/// ```ignore
/// // Provide bidirectional From in your crate:
/// impl From<Quaternion<f64>> for CausalMultiVector<f64> { /* ... */ }
/// impl From<CausalMultiVector<f64>> for Quaternion<f64> { /* ... */ }
///
/// // StandardIso automatically picks up every applicable marker:
/// fn use_iso<F>(q: Quaternion<f64>) -> CausalMultiVector<f64>
/// where
///     StandardIso<Quaternion<f64>, CausalMultiVector<f64>>:
///         DivisionAlgebraIso<Quaternion<f64>, CausalMultiVector<f64>, f64>,
/// {
///     <StandardIso<Quaternion<f64>, CausalMultiVector<f64>> as
///         Iso<Quaternion<f64>, CausalMultiVector<f64>>>::to_target(q)
/// }
/// ```
///
/// # Coherence with named witnesses
///
/// `StandardIso<S, T>` is one specific generic type. Named witnesses (if ever
/// introduced for a multi-convention scenario) are distinct types with
/// non-overlapping impls. The compiler accepts the default `StandardIso<S, T>`
/// and any named witnesses side by side without ambiguity.
///
/// # Discipline note
///
/// The blanket impls trust the consumer's `From` impls to satisfy the
/// corresponding homomorphism laws. There is no compile-time check —
/// property-test discipline is the only enforcement. Reviewers should reject
/// bidirectional `From` impls that lack the corresponding `proptest!` blocks
/// when the type pair is one the codebase will rely on as an iso.
pub struct StandardIso<S, T> {
    // Using `fn() -> T` style in the PhantomData makes the auto-trait and
    // derive impls free of bounds on `S` and `T` (the type parameters never
    // participate in any runtime value carried by the witness). This avoids
    // forcing consumers to add Clone/Copy/Debug/Default constraints on
    // their type parameters when bounding generic code on `StandardIso`.
    _marker_s: PhantomData<fn() -> S>,
    _marker_t: PhantomData<fn() -> T>,
}

impl<S, T> StandardIso<S, T> {
    /// Construct a `StandardIso<S, T>` witness. The witness carries no
    /// runtime data; this is purely a marker constructor.
    #[inline]
    pub const fn new() -> Self {
        StandardIso {
            _marker_s: PhantomData,
            _marker_t: PhantomData,
        }
    }
}

impl<S, T> Clone for StandardIso<S, T> {
    #[inline]
    fn clone(&self) -> Self {
        *self
    }
}

impl<S, T> Copy for StandardIso<S, T> {}

impl<S, T> Default for StandardIso<S, T> {
    #[inline]
    fn default() -> Self {
        Self::new()
    }
}

impl<S, T> fmt::Debug for StandardIso<S, T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("StandardIso")
    }
}

// =============================================================================
// Blanket impls
// =============================================================================

impl<S, T> Iso<S, T> for StandardIso<S, T>
where
    S: From<T>,
    T: From<S>,
{
    #[inline]
    fn to_target(s: S) -> T {
        T::from(s)
    }

    #[inline]
    fn to_source(t: T) -> S {
        S::from(t)
    }
}

impl<S, T> GroupIso<S, T> for StandardIso<S, T>
where
    S: Group + From<T>,
    T: Group + From<S>,
{
}

impl<S, T> RingIso<S, T> for StandardIso<S, T>
where
    S: Ring + From<T>,
    T: Ring + From<S>,
{
}

impl<S, T> FieldIso<S, T> for StandardIso<S, T>
where
    S: Field + From<T>,
    T: Field + From<S>,
{
}

impl<S, T, R> AlgebraIso<S, T, R> for StandardIso<S, T>
where
    S: Algebra<R> + From<T>,
    T: Algebra<R> + From<S>,
    R: Ring,
{
}

impl<S, T, R> DivisionAlgebraIso<S, T, R> for StandardIso<S, T>
where
    S: DivisionAlgebra<R> + From<T>,
    T: DivisionAlgebra<R> + From<S>,
    R: Field,
{
}
