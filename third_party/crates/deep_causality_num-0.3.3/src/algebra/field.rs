/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CommutativeRing, InvMonoid};
use core::ops::{Div, DivAssign};

/// Represents a **Field** in abstract algebra.
///
/// A field is a set on which addition, subtraction, multiplication, and division
/// are defined and behave as the corresponding operations on rational and real
/// numbers do. A field is thus a fundamental algebraic structure which is widely
/// used in algebra, number theory, and many other areas of mathematics.
///
/// # Mathematical Definition
///
/// A field is a `CommutativeRing` where every non-zero element has a
/// multiplicative inverse. This means it satisfies the following laws:
///
/// 1.  **CommutativeRing Laws:**
///     - Forms an `AbelianGroup` under addition (associative, commutative, identity `0`, inverses).
///     - Forms a `MulMonoid` under multiplication (associative, identity `1`).
///     - Multiplication is commutative (`a * b = b * a`).
///     - Multiplication distributes over addition (`a * (b + c) = a*b + a*c`).
///
/// 2.  **Multiplicative Inverse:**
///     - For every element `a` not equal to `0`, there exists an element `a⁻¹`
///       such that `a * a⁻¹ = 1`. (Provided by the `InvMonoid` trait)
///
/// ## Examples
/// - Real numbers (`f32`, `f64`)
/// - Complex numbers (`Complex<T>`)
/// - Rational numbers (not implemented in this crate)
///
/// ## Counter-examples
/// - Integers (`i32`, `i64`): Lack multiplicative inverses for most elements.
/// - Quaternions (`Quaternion<T>`): Multiplication is not commutative.
pub trait Field: CommutativeRing + InvMonoid + Div<Output = Self> + DivAssign {}

// Blanket Implementation
impl<T> Field for T where T: CommutativeRing + InvMonoid + Div<Output = Self> + DivAssign {}
