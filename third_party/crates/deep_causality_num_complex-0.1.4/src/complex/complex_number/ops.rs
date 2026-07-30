/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Complex, DivisionAlgebra, One, RealField, Zero};

impl<T: RealField> Complex<T> {
    /// Computes the norm (magnitude or absolute value) of the complex number.
    #[inline]
    pub fn norm(&self) -> T {
        self.norm_sqr().sqrt()
    }

    /// Computes the argument (phase angle) of the complex number in radians.
    #[inline]
    pub fn arg(&self) -> T {
        self.im.atan2(self.re)
    }

    /// Raises to an integer power.
    #[inline]
    pub fn powi(&self, n: i32) -> Self {
        if n == 0 {
            return Self::one();
        }
        let mut res = Self::one();
        let mut base = *self;
        let mut n_abs = n.abs();

        while n_abs > 0 {
            if n_abs % 2 == 1 {
                res *= base;
            }
            base = base * base;
            n_abs /= 2;
        }

        if n < 0 { res._inverse_impl() } else { res }
    }

    /// Raises a to a real (scalar) power.
    #[inline]
    pub fn powf(&self, n: T) -> Self {
        // (r * (cos(t) + i*sin(t)))^n = r^n * (cos(n*t) + i*sin(n*t))
        let r_pow_n = self.norm().powf(n);
        let n_theta = self.arg() * n;
        Self::new(r_pow_n * n_theta.cos(), r_pow_n * n_theta.sin())
    }

    /// Raises to a complex power.
    #[inline]
    pub fn powc(&self, n: Self) -> Self {
        // z^w = exp(w * ln(z))
        (n * self.ln()).exp()
    }

    /// Computes the principal square root of a complex number.
    #[inline]
    pub fn sqrt(self) -> Self {
        if self.is_zero() {
            return Self::zero();
        }
        let norm = self.norm();
        let half = T::one() / (T::one() + T::one());
        let re_sqrt = ((norm + self.re) * half).sqrt();
        let im_sqrt = ((norm - self.re) * half).sqrt();

        if self.im >= T::zero() {
            Self::new(re_sqrt, im_sqrt)
        } else {
            Self::new(re_sqrt, -im_sqrt)
        }
    }

    /// Computes `e^(self)`, where `e` is the base of the natural logarithm.
    #[inline]
    pub fn exp(self) -> Self {
        // e^(a + bi) = e^a * (cos(b) + i * sin(b))
        let exp_re = self.re.exp();
        Self::new(exp_re * self.im.cos(), exp_re * self.im.sin())
    }

    /// Computes the natural logarithm of a complex number.
    #[inline]
    pub fn ln(self) -> Self {
        // ln(z) = ln(|z|) + i * arg(z)
        Self::new(self.norm().ln(), self.arg())
    }

    /// Computes the sine of a complex number.
    #[inline]
    pub fn sin(self) -> Self {
        Self::new(
            self.re.sin() * self.im.cosh(),
            self.re.cos() * self.im.sinh(),
        )
    }

    /// Computes the cosine of a complex number.
    #[inline]
    pub fn cos(self) -> Self {
        Self::new(
            self.re.cos() * self.im.cosh(),
            -self.re.sin() * self.im.sinh(),
        )
    }

    /// Computes the tangent of a complex number.
    #[inline]
    pub fn tan(self) -> Self {
        self.sin() / self.cos()
    }

    /// Computes the hyperbolic sine of a complex number.
    #[inline]
    pub fn sinh(self) -> Self {
        Self::new(
            self.re.sinh() * self.im.cos(),
            self.re.cosh() * self.im.sin(),
        )
    }

    /// Computes the hyperbolic cosine of a complex number.
    #[inline]
    pub fn cosh(self) -> Self {
        Self::new(
            self.re.cosh() * self.im.cos(),
            self.re.sinh() * self.im.sin(),
        )
    }

    /// Computes the hyperbolic tangent of a complex number.
    #[inline]
    pub fn tanh(self) -> Self {
        self.sinh() / self.cosh()
    }
}
