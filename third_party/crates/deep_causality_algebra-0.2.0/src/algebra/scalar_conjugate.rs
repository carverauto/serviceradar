/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{FromPrimitive, One, RealField, Scalar, Zero};
use core::ops::{Add, AddAssign, Div, Mul, MulAssign, Neg, Sub, SubAssign};

/// A scalar carrying a **conjugation** and a real **modulus**, spanning the three scalar families
/// numerical linear algebra cares about: real fields, dual numbers (forward-mode AD), and complex.
///
/// `deep_causality_num` splits its scalar tower along orderability: [`Real`](crate::Real) /
/// [`Scalar`] cover ordered analytic scalars (`f32`/`f64`/`Float106`, and `Dual` for AD), while
/// complex numbers are unordered and live under [`Normed`](crate::Normed) / [`ComplexField`](crate::ComplexField). Those
/// worlds are incomparable, so no single stock bound covers them. `ConjugateScalar` is the bridge: it
/// names exactly the capabilities a Hermitian SVD / QR / inner-product / norm kernel needs —
/// conjugation (the identity for reals), a real squared modulus, the real part, and injection of a
/// real — so one generic implementation serves all three. The kernels reduce to their plain real
/// arithmetic when `conjugate` is the identity and `modulus_squared` is `x²`.
///
/// # Why not a supertrait of [`NormedScalar`](crate::NormedScalar)
/// [`NormedScalar`](crate::NormedScalar) (= [`Field`](crate::Field) + [`Normed`](crate::Normed)) is the cleaner
/// composition but its real type is a [`RealField`](crate::RealField). `ConjugateScalar` instead ties
/// its associated [`Real`](Self::Real) to the weaker [`Scalar`], because `Dual` is **not** a field or
/// `Normed` and its magnitude must remain a `Dual` for derivatives to flow through singular values.
/// For real and complex scalars the two notions agree; only `Dual` forces the weaker bound.
///
/// # Coherence
/// Implemented over the disjoint type constructors `T: RealField` (the real fields), `Dual<T>`, and
/// `Complex<T>`. A blanket `impl<T: Scalar>` would collide with the `Complex<T>` impl, but the
/// `RealField` blanket does not — `num` owns `RealField`, `Dual`, and `Complex` and can prove none of
/// the latter two is a `RealField` (the same reasoning [`Normed`](crate::Normed) relies on).
pub trait ConjugateScalar:
    Copy
    + PartialEq
    + Add<Output = Self>
    + Sub<Output = Self>
    + Mul<Output = Self>
    + Div<Output = Self>
    + Neg<Output = Self>
    + AddAssign
    + SubAssign
    + MulAssign
    + Zero
    + One
    + FromPrimitive
{
    /// The ordered real type carrying magnitudes, singular values, and truncation thresholds
    /// (`Self` for reals, `Dual` for `Dual`, the underlying real for `Complex`).
    type Real: Scalar;

    /// The complex conjugate — the identity for real and dual scalars, `a − bi` for complex.
    fn conjugate(&self) -> Self;

    /// The squared modulus as a real: `x²` for reals/duals, `re² + im²` for complex.
    fn modulus_squared(&self) -> Self::Real;

    /// The real part as a `Real`: `self` for reals/duals, `re` for complex.
    fn real_part(&self) -> Self::Real;

    /// Injects a real scalar: `r` for reals/duals, `r + 0·i` for complex.
    fn from_real(re: Self::Real) -> Self;
}

/// Real fields: conjugation is the identity, the modulus is `x²`, the real type is `Self`. The
/// `RealField` blanket covers `f32`/`f64`/`Float106` in one impl.
impl<T: RealField + FromPrimitive> ConjugateScalar for T {
    type Real = T;
    #[inline]
    fn conjugate(&self) -> Self {
        *self
    }
    #[inline]
    fn modulus_squared(&self) -> T {
        *self * *self
    }
    #[inline]
    fn real_part(&self) -> T {
        *self
    }
    #[inline]
    fn from_real(re: T) -> Self {
        re
    }
}
