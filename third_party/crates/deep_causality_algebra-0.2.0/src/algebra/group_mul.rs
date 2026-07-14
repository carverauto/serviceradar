/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{InvMonoid, MulMonoid};
use core::ops::{Div, DivAssign};

/// Represents a **Multiplicative Group**.
///
/// A multiplicative group is a `Group` where the binary operation is
/// multiplication (`*`).
///
/// # Mathematical Definition
///
/// A set `G` is a group under multiplication if it satisfies:
/// 1.  **Closure:** `a * b` is in `G`. (Implicit in Rust).
/// 2.  **Associativity:** `(a * b) * c = a * (b * c)`. (Implied by `MulMonoid`).
/// 3.  **Identity Element:** There is an element `1` such that `a * 1 = a`.
///     (Provided by the `MulMonoid` -> `One` trait).
/// 4.  **Inverse Element:** For each `a`, there is an inverse `a⁻¹` such that
///     `a * a⁻¹ = 1`. (Provided by the `InvMonoid` trait).
///
/// In a `Field`, the set of all non-zero elements forms a multiplicative group.
pub trait MulGroup: MulMonoid + InvMonoid + Div<Output = Self> + DivAssign {}

// Blanket implementation
impl<T> MulGroup for T where T: MulMonoid + InvMonoid + Div<Output = Self> + DivAssign {}
