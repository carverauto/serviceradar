/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Dual, Real};
use core::ops::Div;

/// `Dual<T>` is itself an analytic real scalar: every elementary function carries its
/// closed-form derivative through the `ε` channel by the chain rule
/// (`f(a + bε) = f(a) + f'(a)·b·ε`). Non-smooth operations (`floor`, `ceil`, `round`,
/// the constants) propagate a zero `ε`. Because `Dual<T>: Real`, a dual flows through any
/// `Real`-generic numeric, and duals nest: `Dual<Dual<T>>` recovers second derivatives.
///
/// `Dual<T>` is **not** a `Field`/`RealField` (see the algebra module): `ε` is a zero
/// divisor, so there is no total inverse.
impl<T: Real + Div<Output = T>> Real for Dual<T> {
    #[inline]
    fn nan() -> Self {
        Self::new(T::nan(), T::zero())
    }

    #[inline]
    fn is_nan(self) -> bool {
        self.re.is_nan()
    }

    #[inline]
    fn is_infinite(self) -> bool {
        self.re.is_infinite()
    }

    #[inline]
    fn is_finite(self) -> bool {
        self.re.is_finite()
    }

    #[inline]
    fn clamp(self, min: Self, max: Self) -> Self {
        // Clamp by value; at a boundary the result is the bound (carrying the bound's
        // derivative, which is zero for constant bounds), otherwise a passthrough.
        if self.re < min.re {
            min
        } else if self.re > max.re {
            max
        } else {
            self
        }
    }

    #[inline]
    fn sqrt(self) -> Self {
        // d/dx √x = 1 / (2√x)
        let s = self.re.sqrt();
        Self::new(s, self.du / (s * (T::one() + T::one())))
    }

    #[inline]
    fn abs(self) -> Self {
        // d/dx |x| = sign(x)
        if self.re < T::zero() {
            Self::new(self.re.abs(), -self.du)
        } else {
            Self::new(self.re.abs(), self.du)
        }
    }

    #[inline]
    fn floor(self) -> Self {
        Self::new(self.re.floor(), T::zero())
    }

    #[inline]
    fn ceil(self) -> Self {
        Self::new(self.re.ceil(), T::zero())
    }

    #[inline]
    fn round(self) -> Self {
        Self::new(self.re.round(), T::zero())
    }

    #[inline]
    fn exp(self) -> Self {
        // d/dx eˣ = eˣ
        let e = self.re.exp();
        Self::new(e, e * self.du)
    }

    #[inline]
    fn ln(self) -> Self {
        // d/dx ln x = 1/x
        Self::new(self.re.ln(), self.du / self.re)
    }

    #[inline]
    fn log(self, base: Self) -> Self {
        // log_base(x) = ln(x) / ln(base); chain rule via dual division.
        self.ln() / base.ln()
    }

    #[inline]
    fn log2(self) -> Self {
        // d/dx log₂ x = 1 / (x · ln 2)
        let two = T::one() + T::one();
        Self::new(self.re.log2(), self.du / (self.re * two.ln()))
    }

    #[inline]
    fn log10(self) -> Self {
        // d/dx log₁₀ x = 1 / (x · ln 10)
        let two = T::one() + T::one();
        let five = two + two + T::one();
        let ten = two * five;
        Self::new(self.re.log10(), self.du / (self.re * ten.ln()))
    }

    #[inline]
    fn powf(self, n: Self) -> Self {
        // xⁿ = exp(n · ln x); chain rule via dual ops (handles both base and exponent).
        (n * self.ln()).exp()
    }

    #[inline]
    fn sin(self) -> Self {
        // d/dx sin x = cos x
        Self::new(self.re.sin(), self.re.cos() * self.du)
    }

    #[inline]
    fn asin(self) -> Self {
        // d/dx asin x = 1 / √(1 − x²)
        let d = (T::one() - self.re * self.re).sqrt();
        Self::new(self.re.asin(), self.du / d)
    }

    #[inline]
    fn cos(self) -> Self {
        // d/dx cos x = −sin x
        Self::new(self.re.cos(), -(self.re.sin() * self.du))
    }

    #[inline]
    fn acos(self) -> Self {
        // d/dx acos x = −1 / √(1 − x²)
        let d = (T::one() - self.re * self.re).sqrt();
        Self::new(self.re.acos(), -(self.du / d))
    }

    #[inline]
    fn tan(self) -> Self {
        // d/dx tan x = 1 / cos²x
        let c = self.re.cos();
        Self::new(self.re.tan(), self.du / (c * c))
    }

    #[inline]
    fn sinh(self) -> Self {
        // d/dx sinh x = cosh x
        Self::new(self.re.sinh(), self.re.cosh() * self.du)
    }

    #[inline]
    fn cosh(self) -> Self {
        // d/dx cosh x = sinh x
        Self::new(self.re.cosh(), self.re.sinh() * self.du)
    }

    #[inline]
    fn tanh(self) -> Self {
        // d/dx tanh x = 1 − tanh²x
        let t = self.re.tanh();
        Self::new(t, (T::one() - t * t) * self.du)
    }

    #[inline]
    fn atan(self) -> Self {
        // d/dx atan x = 1 / (1 + x²)
        Self::new(self.re.atan(), self.du / (T::one() + self.re * self.re))
    }

    #[inline]
    fn atan2(self, other: Self) -> Self {
        // d/dt atan2(y, x) = (x·y' − y·x') / (x² + y²), with self = y, other = x.
        let denom = self.re * self.re + other.re * other.re;
        Self::new(
            self.re.atan2(other.re),
            (other.re * self.du - self.re * other.du) / denom,
        )
    }

    #[inline]
    fn pi() -> Self {
        Self::new(T::pi(), T::zero())
    }

    #[inline]
    fn e() -> Self {
        Self::new(T::e(), T::zero())
    }

    #[inline]
    fn epsilon() -> Self {
        Self::new(T::epsilon(), T::zero())
    }
}
