/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Complex, DivisionAlgebra, RealField, Zero};

impl<T: RealField> Complex<T> {
    /// Computes the squared norm (magnitude squared) of the complex number.
    #[inline]
    pub(crate) fn _norm_sqr_impl(&self) -> T {
        self.re * self.re + self.im * self.im
    }
    /// Computes the complex conjugate of the complex number.
    #[inline]
    pub(crate) fn _conjugate_impl(&self) -> Self {
        Self::new(self.re, -self.im)
    }

    /// Computes the multiplicative inverse of an element.
    #[inline]
    pub(crate) fn _inverse_impl(&self) -> Self {
        if self.is_zero() {
            return Self::new(T::nan(), T::nan());
        }
        let inv_norm_sq = self.norm_sqr().inverse();
        Self {
            re: self.re * inv_norm_sq,
            im: -self.im * inv_norm_sq,
        }
    }
}
