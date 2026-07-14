/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The idempotence law for a [`Monoid`](crate::Monoid)'s operation.

use crate::Monoid;

/// An **idempotent** monoid operation:
///
/// - **Idempotence:** `x.clone().combine(x) == x`.
///
/// A count monoid is commutative but NOT idempotent, so this is kept separate from
/// [`CommutativeMonoid`](crate::CommutativeMonoid); a [`BoundedSemilattice`](crate::BoundedSemilattice)
/// is exactly a commutative + idempotent monoid.
pub trait Idempotent: Monoid {}
