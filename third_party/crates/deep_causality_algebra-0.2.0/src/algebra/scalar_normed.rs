/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Field, FromPrimitive, Normed};

/// A **normed scalar**: a field element that also carries a real modulus — the bound for normed
/// linear algebra (norms, orthogonalization, singular values) over either real *or* complex scalars.
///
/// This is a pure **trait composition**: it adds no methods of its own, it just names the
/// conjunction [`Field`] + [`Normed`] + [`FromPrimitive`] + `Copy` and lets a single blanket
/// implementation cover every type that already satisfies all four. Both the real fields
/// (`f32`/`f64`/`Float106`) and `Complex<T>` qualify; the real modulus and the real scalar type are
/// read through [`Normed`] (`Self::Real` is a [`RealField`](crate::RealField)).
///
/// # Relationship to [`ConjugateScalar`](crate::ConjugateScalar)
/// `NormedScalar` deliberately does **not** cover `Dual` (forward-mode AD): a dual number is not a
/// field, and its magnitude carries an infinitesimal, so its real type cannot be a `RealField`
/// without discarding the derivative. Code that must thread derivatives through magnitudes (e.g. a
/// differentiable SVD) uses [`ConjugateScalar`](crate::ConjugateScalar) instead, whose associated
/// real type is the weaker [`Scalar`](crate::Scalar) (admitting `Dual`). For real and complex
/// scalars the two agree; `NormedScalar` is the cleaner choice whenever `Dual` support is not needed.
pub trait NormedScalar: Field + Normed + FromPrimitive + Copy {}

impl<T> NormedScalar for T where T: Field + Normed + FromPrimitive + Copy {}
