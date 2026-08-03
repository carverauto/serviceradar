/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Complex;
use deep_causality_algebra::{ComplexField, ConjugateScalar, RealField};
use deep_causality_num::FromPrimitive;

/// Complex scalars carry a genuine conjugation `a − bi` and a real modulus `re² + im²`; magnitudes
/// and singular values live in the underlying real type `T`.
impl<T: RealField + FromPrimitive> ConjugateScalar for Complex<T> {
    type Real = T;
    #[inline]
    fn conjugate(&self) -> Self {
        ComplexField::conjugate(self)
    }
    #[inline]
    fn modulus_squared(&self) -> T {
        ComplexField::norm_sqr(self)
    }
    #[inline]
    fn real_part(&self) -> T {
        self.re()
    }
    #[inline]
    fn from_real(re: T) -> Self {
        Complex::new(re, T::zero())
    }
}
