/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Small complex helpers shared by the kernels. Multiplication by `±i` is
//! a component swap, not a full complex multiply, which is what the radix-4
//! butterflies rely on.

use deep_causality_num_complex::Complex;

use crate::traits::fft_scalar::FftScalar;

/// The complex zero.
#[inline]
pub(crate) fn czero<R: FftScalar>() -> Complex<R> {
    Complex::new(R::zero(), R::zero())
}

/// `i · c` without a complex multiply.
#[inline]
pub(crate) fn mul_i<R: FftScalar>(c: Complex<R>) -> Complex<R> {
    Complex::new(-c.im, c.re)
}

/// `−i · c` without a complex multiply.
#[inline]
pub(crate) fn mul_neg_i<R: FftScalar>(c: Complex<R>) -> Complex<R> {
    Complex::new(c.im, -c.re)
}

/// Complex conjugate.
#[inline]
pub(crate) fn conj<R: FftScalar>(c: Complex<R>) -> Complex<R> {
    Complex::new(c.re, -c.im)
}

/// `c` scaled by the real factor `r`.
#[inline]
pub(crate) fn scale<R: FftScalar>(c: Complex<R>, r: R) -> Complex<R> {
    Complex::new(c.re * r, c.im * r)
}

/// Conjugate every element in place.
#[inline]
pub(crate) fn conj_in_place<R: FftScalar>(data: &mut [Complex<R>]) {
    for z in data.iter_mut() {
        *z = conj(*z);
    }
}
