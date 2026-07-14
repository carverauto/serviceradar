/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{FromPrimitive, Real};
use core::ops::Div;

///
/// `Scalar` sits in the real tower between [`Real`](crate::Real) and
/// [`RealField`](crate::RealField): it adds division to `Real` but, unlike a field, does **not**
/// require a total inverse. That is deliberate, so that [`Dual`](crate::Dual) qualifies — its `ε`
/// component is a zero divisor, so it has division yet is not a field. The
/// `deep_causality_calculus` crate writes its differentiation and integration operators against
/// `Scalar`, so a single model evaluates at `f64` (the value) and at `Dual` (the derivative).
///
/// - [`Real`](crate::Real) supplies ring arithmetic and the elementary functions (the analytic
///   axis), without requiring field division.
/// - `Div` lets `Dual` itself be a `Real`, so the tangent functor **nests** (`Dual<Dual<…>>` gives
///   higher derivatives).
/// - [`FromPrimitive`](crate::FromPrimitive) is the precision-safe constant lift: a model raises
///   its literal constants into the working scalar at any precision (`f32` / `f64` / `Float106`,
///   and `Dual` over each via the blanket impl in this crate). `From<f64>` is deliberately *not*
///   used, because `f32` does not implement it.
///
/// This is distinct from multivector's `ScalarEval` (which abstracts a value's real *modulus* over
/// Real/Complex for norm work); `Scalar` is the differentiation *variable*.
///
pub trait Scalar: Real + Div<Output = Self> + FromPrimitive {}

/// Blanket-implemented, so every qualifying Real number is a `Scalar` automatically.
impl<T: Real + Div<Output = T> + FromPrimitive> Scalar for T {}
