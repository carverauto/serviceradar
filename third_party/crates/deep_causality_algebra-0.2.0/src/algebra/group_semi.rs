/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::algebra::associative::Associative;
use core::ops::{Add, Mul};

/// Represents an **Additive Semigroup**.
///
/// A semigroup is an algebraic structure with a single associative binary
/// operation. Unlike a monoid, a semigroup does NOT require an identity element.
///
/// # Mathematical Definition
///
/// A set `S` with a binary operation `+` is an additive semigroup if:
/// 1. **Closure:** `a + b` is in `S` for all `a, b` in `S`. (Implicit in Rust).
/// 2. **Associativity:** `(a + b) + c = a + (b + c)` for all `a, b, c` in `S`.
///
/// # Examples
/// - Positive integers under addition (no zero identity).
/// - Non-empty strings under concatenation.
pub trait AddSemigroup: Add<Output = Self> + Associative + Clone {}

// Blanket implementation
impl<T> AddSemigroup for T where T: Add<Output = Self> + Associative + Clone {}

/// Represents a **Multiplicative Semigroup**.
///
/// A semigroup is an algebraic structure with a single associative binary
/// operation. Unlike a monoid, a semigroup does NOT require an identity element.
///
/// # Mathematical Definition
///
/// A set `S` with a binary operation `*` is a multiplicative semigroup if:
/// 1. **Closure:** `a * b` is in `S` for all `a, b` in `S`. (Implicit in Rust).
/// 2. **Associativity:** `(a * b) * c = a * (b * c)` for all `a, b, c` in `S`.
///
/// # Hierarchy
/// ```text
/// Magma (closure only)
///   ↓
/// Semigroup (+ associativity)
///   ↓
/// Monoid (+ identity)
/// ```
pub trait MulSemigroup: Mul<Output = Self> + Associative + Clone {}

// Blanket implementation
impl<T> MulSemigroup for T where T: Mul<Output = Self> + Associative + Clone {}
