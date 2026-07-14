/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Ring;
use crate::iso::group_iso::GroupIso;

/// Marker trait asserting that a bidirectional `From` conversion between `Self`
/// and `T` is a ring homomorphism.
///
/// `RingIso<T>` extends [`GroupIso<T>`] — implementing this trait requires
/// `GroupIso<T>` to also be implemented (the additive group homomorphism
/// remains a precondition) — and adds the multiplicative homomorphism law:
///
/// 1. **Addition** — `T::from(a + b) == T::from(a) + T::from(b)` (inherited
///    from `GroupIso<T>`).
/// 2. **Multiplication** — `T::from(a * b) == T::from(a) * T::from(b)` for all
///    `a, b: Self`.
/// 3. **Round-trip identity** (inherited from `GroupIso<T>` precondition).
///
/// The where-clauses promote `Self` and `T` to `Ring`. The trait body is empty;
/// the laws are verified by
/// [`crate::iso::test_support::assert_ring_iso_from_laws`].
///
/// # Inheritance chain
///
/// `GroupIso<T>` → `RingIso<T>` → [`crate::iso::FieldIso<T>`] (when both sides
/// are also `Field`). Implementing the most specific marker in the chain
/// requires implementing each parent as a separate (empty-body) `impl` block.
pub trait RingIso<T>: GroupIso<T>
where
    Self: Ring + From<T>,
    T: Ring + From<Self>,
{
}
