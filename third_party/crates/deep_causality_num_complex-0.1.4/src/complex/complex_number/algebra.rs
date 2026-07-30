/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{
    AbelianGroup, Associative, Commutative, Complex, ComplexField, Distributive, DivisionAlgebra,
    RealField,
};
// | Type | `Distributive` | `Associative` | `Commutative` | Trait |
// | :--- | :---: | :---: | :---: | :--- |
// | **Complex** | ✅ | ✅ | ✅ | `Field`  `ComplexField` |

// Marker Traits
impl<T: RealField> Associative for Complex<T> {}
impl<T: RealField> Commutative for Complex<T> {}
impl<T: RealField> Distributive for Complex<T> {}
impl<T: RealField> AbelianGroup for Complex<T> {}

// The blanket impls for AssociativeRing, Field, and AssociativeDivisionAlgebra
// will apply automatically as Complex<T> now satisfies their super-traits.

// Implement all methods for DivisionAlgebra, delegating to inherent methods.
impl<T: RealField> DivisionAlgebra<T> for Complex<T> {
    fn conjugate(&self) -> Self {
        self._conjugate_impl()
    }

    fn norm_sqr(&self) -> T {
        self._norm_sqr_impl()
    }

    fn inverse(&self) -> Self {
        self._inverse_impl()
    }
}

// Implement ComplexField for Complex<T>
impl<T: RealField> ComplexField<T> for Complex<T> {
    #[inline]
    fn real(&self) -> T {
        self.re
    }

    #[inline]
    fn imag(&self) -> T {
        self.im
    }

    #[inline]
    fn conjugate(&self) -> Self {
        self._conjugate_impl()
    }

    #[inline]
    fn norm_sqr(&self) -> T {
        self._norm_sqr_impl()
    }

    #[inline]
    fn norm(&self) -> T {
        self._norm_sqr_impl().sqrt()
    }

    #[inline]
    fn arg(&self) -> T {
        self.im.atan2(self.re)
    }

    #[inline]
    fn from_re_im(re: T, im: T) -> Self {
        Self::new(re, im)
    }

    #[inline]
    fn from_polar(r: T, theta: T) -> Self {
        Self::new(r * theta.cos(), r * theta.sin())
    }

    #[inline]
    fn i() -> Self {
        Self::new(T::zero(), T::one())
    }

    #[inline]
    fn is_real(&self) -> bool {
        self.im.is_zero()
    }

    #[inline]
    fn is_imaginary(&self) -> bool {
        self.re.is_zero()
    }
}
