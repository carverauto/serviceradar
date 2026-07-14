/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Ring;
use crate::algebra::commutative::Commutative;

/// A marker trait for a **Commutative Ring**.
///
/// A commutative ring is a `Ring` where the multiplication operation is
/// commutative. This means the order of operands in multiplication does not
/// affect the result.
///
/// # Mathematical Definition
///
/// A ring `(R, +, *)` is commutative if it satisfies the following additional law:
///
/// 1.  **Commutativity of Multiplication:** `a * b = b * a` for all `a, b` in `R`.
///
/// ## Note on Implementation
///
/// This is a **marker trait** and has no methods. Its purpose is to signal at the
/// type level that the commutativity law holds. The compiler cannot verify this
/// law, so implementing this trait is a promise by the developer that the
/// underlying type's multiplication is commutative.
///
/// This property is particularly important for constructs like matrix algebra,
/// where certain properties (e.g., of the determinant) depend on the underlying
/// ring being commutative.
pub trait CommutativeRing: Ring + Commutative {}

// Blanket implementation
impl<T> CommutativeRing for T where T: Ring + Commutative {}
