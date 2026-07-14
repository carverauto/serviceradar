/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use core::ops::{Add, AddAssign, Mul};

/// An Additive Magma.
///
/// Definition: A set equipped with a binary operation `+`.
///
/// Requirements:
/// 1. Closure: If `a` and `b` are in the set, `a + b` is in the set.
///
/// It does NOT guarantee Associativity: (a + b) + c != a + (b + c).
/// It does NOT guarantee Identity (Zero).
pub trait AddMagma: Add<Output = Self> + AddAssign + Clone + PartialEq {}

// Blanket Implementation
impl<T> AddMagma for T where T: Add<Output = Self> + AddAssign + Clone + PartialEq {}

// A Magma is just a set with multiplication (No laws guaranteed).
// Octonions live here.
pub trait MulMagma: Mul<Output = Self> + Clone {}

// Blanket implementation
impl<T> MulMagma for T where T: Mul<Output = Self> + Clone {}
