/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{One, Quaternion, RealField, Zero};
use core::iter::{Product, Sum};
use core::ops::{Add, AddAssign, Div, DivAssign, Mul, MulAssign, Sub, SubAssign};

// Sum
impl<F: RealField> Sum for Quaternion<F> {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Quaternion::zero(), |acc, x| acc + x)
    }
}

// Product
impl<F: RealField> Product for Quaternion<F> {
    fn product<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Quaternion::one(), |acc, x| acc * x)
    }
}

// Add
impl<T: RealField> Add for Quaternion<T> {
    type Output = Self;
    fn add(self, other: Self) -> Self {
        Quaternion {
            w: self.w + other.w,
            x: self.x + other.x,
            y: self.y + other.y,
            z: self.z + other.z,
        }
    }
}

// AddAssign
impl<T: RealField> AddAssign for Quaternion<T> {
    #[inline]
    fn add_assign(&mut self, other: Self) {
        self.w += other.w;
        self.x += other.x;
        self.y += other.y;
        self.z += other.z;
    }
}

// Sub
impl<F: RealField> Sub for Quaternion<F> {
    type Output = Self;

    fn sub(self, other: Self) -> Self {
        Quaternion {
            w: self.w - other.w,
            x: self.x - other.x,
            y: self.y - other.y,
            z: self.z - other.z,
        }
    }
}

impl<F: RealField> SubAssign for Quaternion<F> {
    fn sub_assign(&mut self, other: Self) {
        self.w -= other.w;
        self.x -= other.x;
        self.y -= other.y;
        self.z -= other.z;
    }
}

// Mul (Quaternion multiplication)
impl<F: RealField> Mul for Quaternion<F> {
    type Output = Self;
    fn mul(self, other: Self) -> Self {
        let (w1, x1, y1, z1) = (self.w, self.x, self.y, self.z);
        let (w2, x2, y2, z2) = (other.w, other.x, other.y, other.z);

        Quaternion {
            w: w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
            x: w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
            y: w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
            z: w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
        }
    }
}
impl<F: RealField> MulAssign for Quaternion<F> {
    fn mul_assign(&mut self, other: Self) {
        *self = *self * other;
    }
}

// Mul (Scalar multiplication)
impl<F: RealField> Mul<F> for Quaternion<F> {
    type Output = Self;

    fn mul(self, scalar: F) -> Self {
        Quaternion {
            w: self.w * scalar,
            x: self.x * scalar,
            y: self.y * scalar,
            z: self.z * scalar,
        }
    }
}

impl<F: RealField> MulAssign<F> for Quaternion<F> {
    fn mul_assign(&mut self, scalar: F) {
        self.w *= scalar;
        self.x *= scalar;
        self.y *= scalar;
        self.z *= scalar;
    }
}

// Div (Quaternion division)
#[allow(clippy::suspicious_arithmetic_impl)]
impl<F: RealField> Div for Quaternion<F> {
    type Output = Self;

    fn div(self, other: Self) -> Self {
        self * other._inverse_impl()
    }
}

// DivAssign
impl<F: RealField> DivAssign for Quaternion<F> {
    fn div_assign(&mut self, other: Self) {
        *self = *self / other;
    }
}

// Div (Scalar division)
impl<F: RealField> Div<F> for Quaternion<F> {
    type Output = Self;

    fn div(self, scalar: F) -> Self {
        let inv_scalar = F::one() / scalar;
        Quaternion {
            w: self.w * inv_scalar,
            x: self.x * inv_scalar,
            y: self.y * inv_scalar,
            z: self.z * inv_scalar,
        }
    }
}
