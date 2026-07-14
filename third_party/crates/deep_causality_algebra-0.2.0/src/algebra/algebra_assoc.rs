/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Algebra, AssociativeRing, Ring};

/// A marker trait for an **Associative Algebra**.
///
/// This trait identifies an `Algebra` where the multiplication operation is
/// associative. Since the `AssociativeRing` trait (required by this trait's
/// mathematical definition and implied by the explicit `Associative` marker
/// trait for implementors) guarantees associativity of multiplication,
/// this trait explicitly signals that property.
///
/// It is distinct from non-associative algebras like Octonions.
///
/// # Mathematical Definition
///
/// An associative algebra `A` is an algebra that is also an `AssociativeRing`.
/// This means it satisfies the law:
///
/// `(x * y) * z = x * (y * z)` for all `x, y, z` in `A`.
///
/// ## Examples
///
/// - **Associative:** Real numbers, Complex numbers, Quaternions.
/// - **Non-Associative:** Octonions.
pub trait AssociativeAlgebra<R: Ring>: Algebra<R> + AssociativeRing {}

// Blanket implementation
impl<T, R> AssociativeAlgebra<R> for T
where
    T: Algebra<R> + Ring, // Ring implies Associative
    R: Ring,
{
}
