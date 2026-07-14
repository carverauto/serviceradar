/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Float;
use core::num::FpCategory;

#[cfg(all(not(feature = "std"), feature = "libm_math"))]
use libm;

// F32 Helper functions for integer_decode
fn integer_decode_f32(f: f32) -> (u64, i16, i8) {
    let bits: u32 = f.to_bits();
    let sign: i8 = if bits >> 31 == 0 { 1 } else { -1 };
    let mut exponent: i16 = ((bits >> 23) & 0xff) as i16;
    let mantissa = if exponent == 0 {
        (bits & 0x7fffff) << 1
    } else {
        (bits & 0x7fffff) | 0x800000
    };
    // Exponent bias + mantissa shift
    exponent -= 127 + 23;
    (mantissa as u64, exponent, sign)
}

impl Float for f32 {
    #[inline]
    fn nan() -> Self {
        f32::NAN
    }
    #[inline]
    fn infinity() -> Self {
        f32::INFINITY
    }
    #[inline]
    fn neg_infinity() -> Self {
        f32::NEG_INFINITY
    }
    #[inline]
    fn neg_zero() -> Self {
        -0.0
    }
    #[inline]
    fn min_value() -> Self {
        f32::MIN
    }
    #[inline]
    fn min_positive_value() -> Self {
        f32::MIN_POSITIVE
    }
    #[inline]
    fn epsilon() -> Self {
        f32::EPSILON
    }
    #[inline]
    fn pi() -> Self {
        core::f32::consts::PI
    }
    #[inline]
    fn e() -> Self {
        core::f32::consts::E
    }
    #[inline]
    fn max_value() -> Self {
        f32::MAX
    }
    #[inline]
    fn is_nan(self) -> bool {
        f32::is_nan(self)
    }
    #[inline]
    fn is_infinite(self) -> bool {
        f32::is_infinite(self)
    }
    #[inline]
    fn is_finite(self) -> bool {
        f32::is_finite(self)
    }
    #[inline]
    fn is_normal(self) -> bool {
        f32::is_normal(self)
    }
    #[inline]
    fn is_subnormal(self) -> bool {
        f32::is_subnormal(self)
    }
    #[inline]
    fn classify(self) -> FpCategory {
        f32::classify(self)
    }
    #[inline]
    fn floor(self) -> Self {
        #[cfg(feature = "std")]
        return self.floor();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::floorf(self);
    }

    #[inline]
    fn ceil(self) -> Self {
        #[cfg(feature = "std")]
        return self.ceil();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::ceilf(self);
    }

    #[inline]
    fn round(self) -> Self {
        #[cfg(feature = "std")]
        return self.round();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::roundf(self);
    }

    #[inline]
    fn trunc(self) -> Self {
        #[cfg(feature = "std")]
        return self.trunc();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::truncf(self);
    }

    #[inline]
    fn fract(self) -> Self {
        #[cfg(feature = "std")]
        return self.fract();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return self - libm::truncf(self);
    }

    #[inline]
    fn abs(self) -> Self {
        f32::abs(self)
    }

    #[inline]
    fn signum(self) -> Self {
        f32::signum(self)
    }

    #[inline]
    fn is_sign_positive(self) -> bool {
        f32::is_sign_positive(self)
    }

    #[inline]
    fn is_sign_negative(self) -> bool {
        f32::is_sign_negative(self)
    }

    #[inline]
    fn mul_add(self, a: Self, b: Self) -> Self {
        #[cfg(feature = "std")]
        return self.mul_add(a, b);

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::fmaf(self, a, b);
    }

    #[inline]
    fn recip(self) -> Self {
        f32::recip(self)
    }

    #[inline]
    fn powi(self, n: i32) -> Self {
        #[cfg(feature = "std")]
        return self.powi(n);

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::powf(self, n as f32);
    }

    #[inline]
    fn powf(self, n: Self) -> Self {
        #[cfg(feature = "std")]
        return self.powf(n);

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::powf(self, n);
    }

    #[inline]
    fn sqrt(self) -> Self {
        #[cfg(feature = "std")]
        return self.sqrt();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::sqrtf(self);
    }

    #[inline]
    fn exp(self) -> Self {
        #[cfg(feature = "std")]
        return self.exp();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::expf(self);
    }

    #[inline]
    fn exp2(self) -> Self {
        #[cfg(feature = "std")]
        return self.exp2();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::exp2f(self);
    }

    #[inline]
    fn ln(self) -> Self {
        #[cfg(feature = "std")]
        return self.ln();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::logf(self);
    }

    #[inline]
    fn log(self, base: Self) -> Self {
        #[cfg(feature = "std")]
        return self.log(base);

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::logf(self) / libm::logf(base);
    }

    #[inline]
    fn log2(self) -> Self {
        #[cfg(feature = "std")]
        return self.log2();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::log2f(self);
    }

    #[inline]
    fn log10(self) -> Self {
        #[cfg(feature = "std")]
        return self.log10();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::log10f(self);
    }

    #[inline]
    fn to_degrees(self) -> Self {
        f32::to_degrees(self)
    }

    #[inline]
    fn to_radians(self) -> Self {
        f32::to_radians(self)
    }

    #[inline]
    fn max(self, other: Self) -> Self {
        f32::max(self, other)
    }

    #[inline]
    fn min(self, other: Self) -> Self {
        f32::min(self, other)
    }

    #[inline]
    fn clamp(self, min: Self, max: Self) -> Self {
        f32::clamp(self, min, max)
    }

    #[inline]
    fn cbrt(self) -> Self {
        #[cfg(feature = "std")]
        return self.cbrt();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::cbrtf(self);
    }

    #[inline]
    fn hypot(self, other: Self) -> Self {
        #[cfg(feature = "std")]
        return self.hypot(other);

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::hypotf(self, other);
    }

    #[inline]
    fn sin(self) -> Self {
        #[cfg(feature = "std")]
        return self.sin();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::sinf(self);
    }

    #[inline]
    fn cos(self) -> Self {
        #[cfg(feature = "std")]
        return self.cos();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::cosf(self);
    }

    #[inline]
    fn tan(self) -> Self {
        #[cfg(feature = "std")]
        return self.tan();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::tanf(self);
    }

    #[inline]
    fn asin(self) -> Self {
        #[cfg(feature = "std")]
        return self.asin();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::asinf(self);
    }

    #[inline]
    fn acos(self) -> Self {
        #[cfg(feature = "std")]
        return self.acos();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::acosf(self);
    }

    #[inline]
    fn atan(self) -> Self {
        #[cfg(feature = "std")]
        return self.atan();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::atanf(self);
    }

    #[inline]
    fn atan2(self, other: Self) -> Self {
        #[cfg(feature = "std")]
        return self.atan2(other);

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::atan2f(self, other);
    }

    #[inline]
    fn sin_cos(self) -> (Self, Self) {
        #[cfg(feature = "std")]
        return self.sin_cos();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return (libm::sinf(self), libm::cosf(self));
    }

    #[inline]
    fn exp_m1(self) -> Self {
        #[cfg(feature = "std")]
        return self.exp_m1();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::expm1f(self);
    }

    #[inline]
    fn ln_1p(self) -> Self {
        #[cfg(feature = "std")]
        return self.ln_1p();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::log1pf(self);
    }

    #[inline]
    fn sinh(self) -> Self {
        #[cfg(feature = "std")]
        return self.sinh();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::sinhf(self);
    }

    #[inline]
    fn cosh(self) -> Self {
        #[cfg(feature = "std")]
        return self.cosh();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::coshf(self);
    }

    #[inline]
    fn tanh(self) -> Self {
        #[cfg(feature = "std")]
        return self.tanh();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::tanhf(self);
    }

    #[inline]
    fn asinh(self) -> Self {
        #[cfg(feature = "std")]
        return self.asinh();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::asinhf(self);
    }

    #[inline]
    fn acosh(self) -> Self {
        #[cfg(feature = "std")]
        return self.acosh();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::acoshf(self);
    }

    #[inline]
    fn atanh(self) -> Self {
        #[cfg(feature = "std")]
        return self.atanh();

        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        return libm::atanhf(self);
    }

    #[inline]
    fn integer_decode(self) -> (u64, i16, i8) {
        integer_decode_f32(self)
    }

    #[inline]
    fn copysign(self, sign: Self) -> Self {
        f32::copysign(self, sign)
    }
}
