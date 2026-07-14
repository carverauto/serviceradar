/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::AddGroup;

/// Represents a **Group** in abstract algebra.
///
/// A group is a fundamental algebraic structure consisting of a set of elements
/// equipped with a single binary operation that satisfies specific axioms.
///
/// # Mathematical Definition
///
/// A set `G` with a binary operation `*` is a group if it satisfies:
/// 1.  **Closure:** For all `a, b` in `G`, the result `a * b` is also in `G`.
///     (Implicit in Rust's trait system).
/// 2.  **Associativity:** For all `a, b, c` in `G`, `(a * b) * c = a * (b * c)`.
/// 3.  **Identity Element:** There exists an element `e` in `G` such that for
///     every `a` in `G`, `e * a = a * e = a`.
/// 4.  **Inverse Element:** For each `a` in `G`, there exists an element `b` in
///     `G` (the inverse of `a`, denoted `a⁻¹`) such that `a * b = b * a = e`.
///
/// # Crate-Specific Implementation
///
/// This `Group` trait is a general, conceptual trait. In this crate, algebraic
/// structures are typically defined by their primary operation:
/// - `AddGroup`: A group under the addition operation (`+`).
/// - `MulGroup`: A group under the multiplication operation (`*`).
///
/// This trait inherits from `AddGroup` to provide a default group structure based
/// on addition, but it primarily serves as a high-level abstraction.
pub trait Group: AddGroup {}

// Blanket Implementation for all types that impl AddGroup
impl<T: AddGroup> Group for T {}
