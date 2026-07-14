/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Associative;
use crate::Ring;

/// A marker trait for an **Associative Ring**.
///
/// A ring is associative if its multiplication operation is associative.
///
/// # Note on Implementation
///
/// The base `Ring` trait in this crate requires `MulMonoid`, which in turn
/// requires multiplication to be associative. Therefore, any type that
/// implements `Ring` is already an associative ring.
///
/// This trait serves as a semantic marker to make the associative property
/// explicit at the type level, distinguishing it from potential future
/// non-associative ring structures.
///
/// # Mathematical Definition
///
/// An associative ring is a `Ring` that satisfies the law:
/// - `(a * b) * c = a * (b * c)` for all `a, b, c` in the ring.
pub trait AssociativeRing: Ring + Associative {}

// Blanket Implementation for all types that implement Ring
impl<T> AssociativeRing for T where T: Ring + Associative {}
