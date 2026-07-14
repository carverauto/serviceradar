/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Zero;
use core::ops::{Add, Sub};

/// Represents an **Additive Group**.
///
/// An additive group is a `Group` where the binary operation is addition (`+`).
///
/// # Mathematical Definition
///
/// A set `G` is a group under addition if it satisfies:
/// 1.  **Closure:** `a + b` is in `G`. (Implicit in Rust).
/// 2.  **Associativity:** `(a + b) + c = a + (b + c)`. (Implied by `Add` trait).
/// 3.  **Identity Element:** There is an element `0` such that `a + 0 = a`.
///     (Provided by the `Zero` trait).
/// 4.  **Inverse Element:** For each `a`, there is an inverse `-a` such that
///     `a + (-a) = 0`. (Provided by the `Sub` trait, which defines `a - a`).
///
/// The `Clone` bound is included for practical purposes within the Rust type system.
pub trait AddGroup: Add<Output = Self> + Sub<Output = Self> + Zero + Clone {}

// Blanket Implementation for all types that impl Add, Sub, and have zero
impl<T> AddGroup for T where T: Add<Output = T> + Sub<Output = T> + Zero + Clone {}
