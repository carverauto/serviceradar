/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Group;
use crate::iso::witness::iso::Iso;

/// Marker trait asserting that an [`Iso<S, T>`] preserves group structure on
/// the type pair `(S, T)`.
///
/// `GroupIso<S, T>` is **Tier 2**'s structure-preserving analog of the Tier 1
/// [`crate::iso::GroupIso<T>`] marker. The where-clauses constrain the type
/// *pair* (`S: Group`, `T: Group`) rather than the implementer `Self`. The
/// implementer is whichever type the iso is hung from — typically `S`, `T`,
/// or a dedicated witness, picked by orphan-rule placement.
///
/// # Laws
///
/// 1. **Round-trip identity** — inherited from `Iso<S, T>`.
/// 2. **Group homomorphism** — for all `a, b: S`,
///    `<Self as Iso<S, T>>::to_target(a + b) ==
///     <Self as Iso<S, T>>::to_target(a) + <Self as Iso<S, T>>::to_target(b)`.
///    In this crate `Group: AddGroup`, so the group operation is `+`.
///
/// Verified by [`crate::iso::witness::test_support::assert_witness_group_iso_law`].
///
/// # Inheritance
///
/// `GroupIso<S, T>` is extended by [`crate::iso::witness::RingIso<S, T>`]
/// when both `S` and `T` are also `Ring`. Implementing the deeper subtrait
/// requires implementing every parent — empty marker bodies, but separate
/// `impl` blocks.
pub trait GroupIso<S, T>: Iso<S, T>
where
    S: Group,
    T: Group,
{
}
