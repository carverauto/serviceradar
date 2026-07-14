/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{AbelianGroup, Distributive, MulMonoid};

/// Represents a **Ring** in abstract algebra.
///
/// A ring is an algebraic structure with two binary operations, addition and
/// multiplication, that is more general than a `Field` because it does not
/// require multiplicative inverses for all non-zero elements.
///
/// # Mathematical Definition
///
/// A set `R` is a ring if it satisfies the following laws:
///
/// 1.  **Under Addition:** `R` forms an `AbelianGroup`.
///     - Addition is associative: `(a + b) + c = a + (b + c)`
///     - Addition is commutative: `a + b = b + a`
///     - There is an additive identity `0`: `a + 0 = a`
///     - Every element `a` has an additive inverse `-a`: `a + (-a) = 0`
///
/// 2.  **Under Multiplication:** `R` forms a `MulMonoid`.
///     - Multiplication is associative: `(a * b) * c = a * (b * c)`
///     - There is a multiplicative identity `1`: `a * 1 = a`
///
/// 3.  **Distributivity:** Multiplication distributes over addition.
///     - `a * (b + c) = (a * b) + (a * c)` (Left distributivity)
///     - `(a + b) * c = (a * c) + (b * c)` (Right distributivity)
///
/// This trait combines `AbelianGroup` and `MulMonoid` to enforce these properties.
/// The distributivity law is implicitly assumed to be upheld by the `Add` and
/// `Mul` implementations.
pub trait Ring: AbelianGroup + MulMonoid + Distributive {}
// This is a marker trait that combines other traits.
// It guarantees that a type supports `+`, `-`, `*`, `0`, and `1`
// with the expected algebraic properties of a ring.

// Blanket Implementation
impl<T> Ring for T where T: AbelianGroup + MulMonoid + Distributive {}
