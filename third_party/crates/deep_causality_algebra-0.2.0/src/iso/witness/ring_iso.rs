/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Ring;
use crate::iso::witness::group_iso::GroupIso;

/// Marker trait asserting that an `Iso<S, T>` preserves ring structure on the
/// type pair `(S, T)` — addition **and** multiplication.
///
/// `RingIso<S, T>` extends [`GroupIso<S, T>`] and adds the multiplicative
/// homomorphism law. The where-clauses promote `S` and `T` to `Ring`.
///
/// # Laws
///
/// 1. **Group (additive) homomorphism** — inherited from `GroupIso<S, T>`.
/// 2. **Multiplicative homomorphism** — for all `a, b: S`,
///    `<Self as Iso<S, T>>::to_target(a * b) ==
///     <Self as Iso<S, T>>::to_target(a) * <Self as Iso<S, T>>::to_target(b)`.
///
/// Verified by [`crate::iso::witness::test_support::assert_witness_ring_iso_laws`].
pub trait RingIso<S, T>: GroupIso<S, T>
where
    S: Ring,
    T: Ring,
{
}
