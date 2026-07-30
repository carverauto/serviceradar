/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_par::MaybeParallel;

/// Scalar bound for every transform in this crate: a real field with
/// primitive conversions (for twiddle generation and inverse scaling),
/// plus the feature-dependent thread-safety marker.
///
/// Blanket-implemented; `f32`, `f64`, and `Float106` all qualify.
pub trait FftScalar: RealField + FromPrimitive + MaybeParallel {}

impl<T: RealField + FromPrimitive + MaybeParallel> FftScalar for T {}
