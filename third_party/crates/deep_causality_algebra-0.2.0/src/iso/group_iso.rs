/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Group;

/// Marker trait asserting that a bidirectional `From` conversion between `Self`
/// and `T` is a group homomorphism.
///
/// `GroupIso<T>` is **Tier 1** of the isomorphism trait family in
/// `deep_causality_num`. It carries no methods. Implementing this trait is a
/// type-level promise that the bidirectional `From` impls between `Self` and
/// `T` preserve the group operation — i.e. the homomorphism law
/// `T::from(a · b) == T::from(a) · T::from(b)` holds for all `a, b: Self`,
/// and the symmetric law holds for `S::from(...)` from the `T` side.
///
/// In this crate, `Group: AddGroup`, so the group operation is addition (`+`).
/// The promise is therefore concretely: `T::from(a + b) == T::from(a) + T::from(b)`.
///
/// # Laws
///
/// 1. **Bidirectional From** — `Self: From<T>` and `T: From<Self>` are both
///    required (encoded in the trait's where-clause). This is the mechanism
///    that makes a Tier 1 marker meaningful: it commits the type pair to
///    bidirectional conversion before any structure-preservation claim.
///
/// 2. **Round-trip identity** — `S::from(T::from(s)) == s` for all `s: Self`,
///    and the symmetric case `T::from(S::from(t)) == t` for all `t: T`.
///    Required for `From` impls participating in any Tier 1 marker. Not
///    type-system-enforced; verified by property tests in
///    [`crate::iso::test_support`].
///
/// 3. **Group homomorphism** — `T::from(a + b) == T::from(a) + T::from(b)` for
///    all `a, b: Self`. The mechanical content of the marker. Verified by
///    property tests in [`crate::iso::test_support::assert_group_iso_from_law`].
///
/// # Inheritance
///
/// `GroupIso<T>` is the base of the Tier 1 hierarchy: `RingIso<T>: GroupIso<T>`,
/// `FieldIso<T>: RingIso<T>`, etc. Implementing a deeper subtrait requires
/// implementing every parent — empty marker bodies, but separate `impl` blocks.
///
/// # No type-system enforcement
///
/// Rust cannot structurally prove the homomorphism law. The marker is a
/// reviewer-visible contract; CI enforces test coverage; consumers reading
/// generic bounds `where T: GroupIso<U>` understand the round-trip and
/// homomorphism laws hold on the type pair.
pub trait GroupIso<T>
where
    Self: Group + From<T>,
    T: Group + From<Self>,
{
}
