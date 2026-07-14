/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Float, Float106};
use core::num::FpCategory;

impl Float for Float106 {
    #[inline]
    fn nan() -> Self {
        Self {
            hi: f64::NAN,
            lo: f64::NAN,
        }
    }

    #[inline]
    fn infinity() -> Self {
        Self {
            hi: f64::INFINITY,
            lo: f64::INFINITY,
        }
    }

    #[inline]
    fn neg_infinity() -> Self {
        Self {
            hi: f64::NEG_INFINITY,
            lo: f64::NEG_INFINITY,
        }
    }

    #[inline]
    fn neg_zero() -> Self {
        Self { hi: -0.0, lo: -0.0 }
    }

    #[inline]
    fn min_value() -> Self {
        Self {
            hi: f64::MIN,
            lo: 0.0,
        }
    }

    #[inline]
    fn min_positive_value() -> Self {
        Self {
            hi: f64::MIN_POSITIVE,
            lo: 0.0,
        }
    }

    #[inline]
    fn epsilon() -> Self {
        Self::EPSILON
    }

    #[inline]
    fn pi() -> Self {
        Self::PI
    }

    #[inline]
    fn e() -> Self {
        Self::E
    }

    #[inline]
    fn max_value() -> Self {
        Self {
            hi: f64::MAX,
            lo: 0.0,
        }
    }

    #[inline]
    fn is_nan(self) -> bool {
        self.hi.is_nan()
    }

    #[inline]
    fn is_infinite(self) -> bool {
        self.hi.is_infinite()
    }

    #[inline]
    fn is_finite(self) -> bool {
        self.hi.is_finite()
    }

    #[inline]
    fn is_normal(self) -> bool {
        self.hi.is_normal()
    }

    #[inline]
    fn is_subnormal(self) -> bool {
        self.hi.classify() == FpCategory::Subnormal
    }

    #[inline]
    fn classify(self) -> FpCategory {
        self.hi.classify()
    }

    #[inline]
    fn floor(self) -> Self {
        let hi_floor = self.hi.floor();
        if hi_floor == self.hi {
            // hi is integer, check lo
            let lo_floor = self.lo.floor();
            Self::new(hi_floor + lo_floor, 0.0)
        } else {
            Self::from_f64(hi_floor)
        }
    }

    #[inline]
    fn ceil(self) -> Self {
        let hi_ceil = self.hi.ceil();
        if hi_ceil == self.hi {
            let lo_ceil = self.lo.ceil();
            Self::new(hi_ceil + lo_ceil, 0.0)
        } else {
            Self::from_f64(hi_ceil)
        }
    }

    #[inline]
    fn round(self) -> Self {
        let hi_round = self.hi.round();
        if hi_round == self.hi {
            let lo_round = self.lo.round();
            Self::new(hi_round + lo_round, 0.0)
        } else {
            Self::from_f64(hi_round)
        }
    }

    #[inline]
    fn trunc(self) -> Self {
        let hi_trunc = self.hi.trunc();
        if hi_trunc == self.hi {
            let lo_trunc = self.lo.trunc();
            Self::new(hi_trunc + lo_trunc, 0.0)
        } else {
            Self::from_f64(hi_trunc)
        }
    }

    #[inline]
    fn fract(self) -> Self {
        self - self.trunc()
    }

    #[inline]
    fn abs(self) -> Self {
        if self.hi < 0.0 || (self.hi == 0.0 && self.lo < 0.0) {
            -self
        } else {
            self
        }
    }

    #[inline]
    fn signum(self) -> Self {
        if self.is_nan() {
            Self::nan()
        } else if self.hi > 0.0 || (self.hi == 0.0 && self.lo > 0.0) {
            Self::from_f64(1.0)
        } else if self.hi < 0.0 || (self.hi == 0.0 && self.lo < 0.0) {
            Self::from_f64(-1.0)
        } else {
            Self::from_f64(0.0)
        }
    }

    #[inline]
    fn is_sign_positive(self) -> bool {
        self.hi.is_sign_positive()
    }

    #[inline]
    fn is_sign_negative(self) -> bool {
        self.hi.is_sign_negative()
    }

    fn mul_add(self, a: Self, b: Self) -> Self {
        // FMA: self * a + b with higher precision
        self * a + b
    }

    fn recip(self) -> Self {
        Self::from_f64(1.0) / self
    }

    fn powi(self, n: i32) -> Self {
        if n == 0 {
            return Self::from_f64(1.0);
        }

        let mut result = Self::from_f64(1.0);
        let mut base = if n < 0 { self.recip() } else { self };
        let mut exp = n.unsigned_abs();

        while exp > 0 {
            if exp & 1 == 1 {
                result *= base;
            }
            base *= base;
            exp >>= 1;
        }

        result
    }

    fn powf(self, n: Self) -> Self {
        // x^n = exp(n * ln(x))
        if self.hi <= 0.0 {
            if self.hi == 0.0 {
                if n.hi > 0.0 {
                    return Self::from_f64(0.0);
                } else {
                    return Self::infinity();
                }
            }
            return Self::nan();
        }
        (n * self.ln()).exp()
    }

    fn sqrt(self) -> Self {
        if self.hi < 0.0 {
            return Self::nan();
        }
        if self.hi == 0.0 {
            return Self::from_f64(0.0);
        }

        // Newton-Raphson iteration: x_{n+1} = 0.5 * (x_n + a/x_n)
        let x0 = self.hi.sqrt();
        let mut x = Self::from_f64(x0);

        // Two iterations for full precision
        x = (x + self / x) * Self::from_f64(0.5);
        x = (x + self / x) * Self::from_f64(0.5);

        x
    }

    fn exp(self) -> Self {
        // Range reduction: e^x = 2^k * e^r where r = x - k*ln(2)
        if self.hi == 0.0 && self.lo == 0.0 {
            return Self::from_f64(1.0);
        }
        if self.is_nan() {
            return Self::nan();
        }
        if self.hi > 709.0 {
            return Self::infinity();
        }
        if self.hi < -709.0 {
            return Self::from_f64(0.0);
        }

        // k = round(x / ln(2))
        let inv_ln2 = Self::from_f64(core::f64::consts::LOG2_E);
        let k_f = (self * inv_ln2).hi.round();
        let k = k_f as i32;

        // r = x - k * ln(2)
        let r = self - Self::LN_2 * Self::from_f64(k_f);

        // Taylor series for e^r
        let mut sum = Self::from_f64(1.0);
        let mut term = r;
        sum += term;

        for i in 2..60 {
            term = term * r / Self::from_f64(i as f64);
            sum += term;
            if term.abs().hi < 1e-32 {
                break;
            }
        }

        // Multiply by 2^k
        sum * Self::from_f64(2.0_f64.powi(k))
    }

    fn exp2(self) -> Self {
        (self * Self::LN_2).exp()
    }

    fn ln(self) -> Self {
        if self.hi <= 0.0 {
            if self.hi == 0.0 {
                return Self::neg_infinity();
            }
            return Self::nan();
        }
        if self.hi == 1.0 && self.lo == 0.0 {
            return Self::from_f64(0.0);
        }

        // Newton-Raphson: x_{n+1} = x_n + (a - e^{x_n}) / e^{x_n}
        //                        = x_n + a * e^{-x_n} - 1
        let x0 = self.hi.ln();
        let mut x = Self::from_f64(x0);

        // Two iterations
        let exp_x = x.exp();
        x = x + self / exp_x - Self::from_f64(1.0);
        let exp_x = x.exp();
        x = x + self / exp_x - Self::from_f64(1.0);

        x
    }

    fn log(self, base: Self) -> Self {
        self.ln() / base.ln()
    }

    fn log2(self) -> Self {
        self.ln() / Self::LN_2
    }

    fn log10(self) -> Self {
        self.ln() / Self::LN_10
    }

    fn to_degrees(self) -> Self {
        self * Self::from_f64(180.0) / Self::PI
    }

    fn to_radians(self) -> Self {
        self * Self::PI / Self::from_f64(180.0)
    }

    fn max(self, other: Self) -> Self {
        if self.is_nan() {
            return other;
        }
        if other.is_nan() {
            return self;
        }
        if self > other { self } else { other }
    }

    fn min(self, other: Self) -> Self {
        if self.is_nan() {
            return other;
        }
        if other.is_nan() {
            return self;
        }
        if self < other { self } else { other }
    }

    fn clamp(self, min: Self, max: Self) -> Self {
        debug_assert!(min <= max);
        if self < min {
            min
        } else if self > max {
            max
        } else {
            self
        }
    }

    fn cbrt(self) -> Self {
        if self.hi == 0.0 {
            return Self::from_f64(0.0);
        }

        let sign = if self.hi < 0.0 {
            Self::from_f64(-1.0)
        } else {
            Self::from_f64(1.0)
        };
        let abs_self = self.abs();

        // Newton-Raphson: x_{n+1} = (2*x_n + a/x_n^2) / 3
        let x0 = abs_self.hi.cbrt();
        let mut x = Self::from_f64(x0);

        let third = Self::from_f64(1.0 / 3.0);
        x = (x * Self::from_f64(2.0) + abs_self / (x * x)) * third;
        x = (x * Self::from_f64(2.0) + abs_self / (x * x)) * third;

        sign * x
    }

    fn hypot(self, other: Self) -> Self {
        (self * self + other * other).sqrt()
    }

    fn sin(self) -> Self {
        self.sin_cos().0
    }

    fn cos(self) -> Self {
        self.sin_cos().1
    }

    fn tan(self) -> Self {
        self.sin() / self.cos()
    }

    fn asin(self) -> Self {
        if self.hi.abs() > 1.0 {
            return Self::nan();
        }
        if self.hi == 1.0 {
            return Self::FRAC_PI_2;
        }
        if self.hi == -1.0 {
            return -Self::FRAC_PI_2;
        }

        // asin(x) = atan(x / sqrt(1 - x^2))
        let one_minus_x2 = Self::from_f64(1.0) - self * self;
        self.atan2(one_minus_x2.sqrt())
    }

    fn acos(self) -> Self {
        if self.hi.abs() > 1.0 {
            return Self::nan();
        }

        // acos(x) = π/2 - asin(x)
        Self::FRAC_PI_2 - self.asin()
    }

    fn atan(self) -> Self {
        // For atan(1), use known value π/4
        if (self.hi() - 1.0).abs() < 1e-15 && self.lo().abs() < 1e-30 {
            return Self::FRAC_PI_4;
        }
        if (self.hi() + 1.0).abs() < 1e-15 && self.lo().abs() < 1e-30 {
            return -Self::FRAC_PI_4;
        }

        // Use argument reduction: atan(x) = 2*atan(x/(1+sqrt(1+x^2)))
        // This reduces |x| to improve Taylor series convergence
        let x = self;
        let x2 = x * x;
        let sqrt_term = (Self::from_f64(1.0) + x2).sqrt();
        let reduced = x / (Self::from_f64(1.0) + sqrt_term);

        // Taylor series for reduced argument (converges faster)
        let y = reduced;
        let y2 = y * y;
        let mut sum = y;
        let mut term = y;

        for i in 1..80 {
            let n = 2 * i + 1;
            term = -term * y2;
            let contribution = term / Self::from_f64(n as f64);
            sum += contribution;
            if contribution.abs().hi < 1e-33 {
                break;
            }
        }

        // Undo the argument reduction: multiply by 2
        sum * Self::from_f64(2.0)
    }

    fn atan2(self, other: Self) -> Self {
        // Handle special cases
        if other.hi == 0.0 && other.lo == 0.0 {
            if self.hi > 0.0 || (self.hi == 0.0 && self.lo > 0.0) {
                return Self::FRAC_PI_2;
            } else if self.hi < 0.0 || (self.hi == 0.0 && self.lo < 0.0) {
                return -Self::FRAC_PI_2;
            } else {
                return Self::nan();
            }
        }

        let ratio = self / other;
        let atan_ratio = ratio.atan();

        // Adjust based on quadrant
        if other.hi >= 0.0 {
            atan_ratio
        } else if self.hi >= 0.0 {
            atan_ratio + Self::PI
        } else {
            atan_ratio - Self::PI
        }
    }

    fn sin_cos(self) -> (Self, Self) {
        // Range reduction to [-π, π]
        let reduced = self % Self::TWO_PI;
        let x = if reduced.hi > Self::PI.hi {
            reduced - Self::TWO_PI
        } else if reduced.hi < -Self::PI.hi {
            reduced + Self::TWO_PI
        } else {
            reduced
        };

        // Table-based reduction x = k·π/16 + s with |s| ≤ π/32, so the
        // Taylor pair below converges in ~9 terms instead of the ~40+ a
        // full-range argument needs.
        let kf = (x.hi * (16.0 / core::f64::consts::PI)).round();
        let s = x - Self::from_f64(kf) * Self::FRAC_PI_16;
        let k = kf as i32;

        // Taylor pair on the reduced argument, sharing s².
        let s2 = s * s;

        let mut sin_s = s;
        let mut term = s;
        for i in 1..10 {
            let n = 2 * i;
            term = -term * s2 / Self::from_f64((n * (n + 1)) as f64);
            sin_s += term;
            if term.abs().hi < 1e-33 {
                break;
            }
        }

        let mut cos_s = Self::from_f64(1.0);
        let mut term = Self::from_f64(1.0);
        for i in 1..10 {
            let n = 2 * i;
            term = -term * s2 / Self::from_f64((n * (n - 1)) as f64);
            cos_s += term;
            if term.abs().hi < 1e-33 {
                break;
            }
        }

        // Recombine via angle addition with the precomputed sin/cos(k·π/16);
        // sin is odd and cos is even in k. NaN input casts k to 0 and
        // propagates through s.
        let idx = (k.unsigned_abs() as usize).min(16);
        let sin_k = if k < 0 {
            -Self::SIN_K_PI_16[idx]
        } else {
            Self::SIN_K_PI_16[idx]
        };
        let cos_k = Self::COS_K_PI_16[idx];

        (sin_k * cos_s + cos_k * sin_s, cos_k * cos_s - sin_k * sin_s)
    }

    fn exp_m1(self) -> Self {
        // For small x, use Taylor series directly
        if self.abs().hi < 0.5 {
            let mut sum = self;
            let mut term = self;
            for i in 2..60 {
                term = term * self / Self::from_f64(i as f64);
                sum += term;
                if term.abs().hi < 1e-33 {
                    break;
                }
            }
            sum
        } else {
            self.exp() - Self::from_f64(1.0)
        }
    }

    fn ln_1p(self) -> Self {
        // For small x, use Taylor series directly
        if self.abs().hi < 0.5 {
            let mut sum = self;
            let mut term = self;
            for i in 2..80 {
                term = -term * self * Self::from_f64((i - 1) as f64) / Self::from_f64(i as f64);
                sum += term;
                if term.abs().hi < 1e-33 {
                    break;
                }
            }
            sum
        } else {
            (Self::from_f64(1.0) + self).ln()
        }
    }

    fn sinh(self) -> Self {
        // sinh(x) = (e^x - e^{-x}) / 2
        let exp_x = self.exp();
        let exp_neg_x = (-self).exp();
        (exp_x - exp_neg_x) * Self::from_f64(0.5)
    }

    fn cosh(self) -> Self {
        // cosh(x) = (e^x + e^{-x}) / 2
        let exp_x = self.exp();
        let exp_neg_x = (-self).exp();
        (exp_x + exp_neg_x) * Self::from_f64(0.5)
    }

    fn tanh(self) -> Self {
        // tanh(x) = sinh(x) / cosh(x) = (e^{2x} - 1) / (e^{2x} + 1)
        let exp_2x = (self * Self::from_f64(2.0)).exp();
        let one = Self::from_f64(1.0);
        (exp_2x - one) / (exp_2x + one)
    }

    fn asinh(self) -> Self {
        // asinh(x) = ln(x + sqrt(x^2 + 1))
        (self + (self * self + Self::from_f64(1.0)).sqrt()).ln()
    }

    fn acosh(self) -> Self {
        // acosh(x) = ln(x + sqrt(x^2 - 1)) for x >= 1
        if self.hi < 1.0 {
            return Self::nan();
        }
        (self + (self * self - Self::from_f64(1.0)).sqrt()).ln()
    }

    fn atanh(self) -> Self {
        // atanh(x) = 0.5 * ln((1+x)/(1-x)) for |x| < 1
        if self.hi.abs() >= 1.0 {
            if self.hi == 1.0 {
                return Self::infinity();
            } else if self.hi == -1.0 {
                return Self::neg_infinity();
            }
            return Self::nan();
        }
        let one = Self::from_f64(1.0);
        ((one + self) / (one - self)).ln() * Self::from_f64(0.5)
    }

    fn integer_decode(self) -> (u64, i16, i8) {
        self.hi.integer_decode()
    }

    fn copysign(self, sign: Self) -> Self {
        if sign.hi.is_sign_positive() {
            self.abs()
        } else {
            -self.abs()
        }
    }
}
