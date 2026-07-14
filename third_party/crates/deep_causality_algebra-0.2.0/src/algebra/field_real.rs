/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{AbelianGroup, Field, Float, Real};

/// An ordered `Field` that is also an analytic real scalar.
///
/// `RealField` is exactly a [`Real`] that is also a [`Field`]: it adds field
/// invertibility (a total multiplicative inverse / division) on top of the analytic
/// surface (ordering, `sqrt`/`exp`/`ln`/`sin`/…, constants) provided by [`Real`].
///
/// All analytic operations are declared on [`Real`] and inherited here via the
/// supertrait, so every existing `T: RealField` bound resolves the same method set
/// it always did. The split lets analytic-but-non-field types (for example dual
/// numbers, used for automatic differentiation) implement [`Real`] without falsely
/// claiming `Field`/`RealField`.
///
/// This trait abstracts over concrete floating-point types like `f32` and `f64`.
pub trait RealField: Real + Field {}

// Every `Float` is an Abelian group under addition and a `RealField`. The rest of the
// tower (`Ring`, `CommutativeRing`, `Field`, …) is derived automatically from these
// plus the marker blankets, so a new float type needs only `impl Float`.
impl<T> AbelianGroup for T where T: Float {}

impl<T> RealField for T where T: Float {}
