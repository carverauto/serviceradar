/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{AssociativeAlgebra, DivisionAlgebra, Field};

/// A marker trait for an **Associative Division Algebra**.
///
/// This trait identifies a `DivisionAlgebra` where the multiplication operation
/// is also associative. It combines the properties of both traits.
///
/// # Mathematical Definition
///
/// An associative division algebra is a set that is simultaneously an
/// `AssociativeAlgebra` and a `DivisionAlgebra`. This means it supports
/// associative multiplication and that every non-zero element has a
/// multiplicative inverse.
///
/// ## Examples
///
/// - Real numbers (`f32`, `f64`)
/// - Complex numbers (`Complex<T>`)
/// - Quaternions (`Quaternion<T>`)
///
/// A notable counter-example is the Octonions, which form a `DivisionAlgebra`
/// but are not associative.
pub trait AssociativeDivisionAlgebra<R: Field>: DivisionAlgebra<R> + AssociativeAlgebra<R> {}

// Blanket implementation
impl<T, R> AssociativeDivisionAlgebra<R> for T
where
    T: DivisionAlgebra<R> + AssociativeAlgebra<R>,
    R: Field,
{
}
