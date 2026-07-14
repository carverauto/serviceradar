/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::complex::quaternion_number::Quaternion;
use crate::{Matrix3, One, RealField, Vector3};

impl<T: RealField> Quaternion<T> {
    /// Computes the norm (magnitude or absolute value) of the quaternion.
    ///
    /// For a quaternion `q = w + xi + yj + zk`, the norm is `sqrt(w^2 + x^2 + y^2 + z^2)`.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    ///
    /// let q = Quaternion::<f64>::new(1.0, 2.0, 3.0, 4.0);
    /// assert_eq!(q.norm(), (1.0f64*1.0f64 + 2.0f64*2.0f64 + 3.0f64*3.0f64 + 4.0f64*4.0f64).sqrt());
    /// ```
    pub fn norm(&self) -> T {
        self._norm_sqr_impl().sqrt()
    }

    /// Returns a normalized quaternion (unit quaternion).
    ///
    /// A unit quaternion has a norm of 1. If the quaternion is a zero quaternion,
    /// it returns itself to avoid division by zero.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    ///
    /// let q = Quaternion::<f64>::new(1.0, 2.0, 3.0, 4.0);
    /// let normalized_q = q.normalize();
    /// assert!((normalized_q.norm() - 1.0).abs() < 1e-9);
    ///
    /// let zero_q = Quaternion::<f64>::new(0.0, 0.0, 0.0, 0.0);
    /// assert_eq!(zero_q.normalize(), zero_q);
    /// ```
    pub fn normalize(&self) -> Self {
        let n = self.norm();
        if n.is_zero() { *self } else { *self / n }
    }

    /// Computes the dot product with another quaternion.
    ///
    /// For two quaternions `q1 = w1 + x1i + y1j + z1k` and `q2 = w2 + x2i + y2j + z2k`,
    /// their dot product is `w1*w2 + x1*x2 + y1*y2 + z1*z2`.
    ///
    /// # Arguments
    ///
    /// * `other` - The other quaternion.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    ///
    /// let q1 = Quaternion::new(1.0, 2.0, 3.0, 4.0);
    /// let q2 = Quaternion::new(5.0, 6.0, 7.0, 8.0);
    /// assert_eq!(q1.dot(&q2), 1.0*5.0 + 2.0*6.0 + 3.0*7.0 + 4.0*8.0);
    /// ```
    pub fn dot(&self, other: &Self) -> T {
        self.w * other.w + self.x * other.x + self.y * other.y + self.z * other.z
    }

    /// Converts the quaternion to an axis-angle representation.
    ///
    /// Returns a tuple containing a 3-element array representing the rotation axis
    /// and the rotation angle in radians.
    ///
    /// If the quaternion is an identity quaternion (or very close to it),
    /// the angle will be 0 and the axis will be an arbitrary unit vector (e.g., `[1.0, 0.0, 0.0]`).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use std::f64::consts::FRAC_PI_2;
    ///
    /// let q = Quaternion::from_axis_angle([1.0, 0.0, 0.0], FRAC_PI_2);
    /// let (axis, angle) = q.to_axis_angle();
    ///
    /// assert!((axis[0] - 1.0).abs() < 1e-9);
    /// assert!((axis[1] - 0.0).abs() < 1e-9);
    /// assert!((axis[2] - 0.0).abs() < 1e-9);
    /// assert!((angle - FRAC_PI_2).abs() < 1e-9);
    /// ```
    pub fn to_axis_angle(&self) -> (Vector3<T>, T) {
        let two = T::one() + T::one();
        let mut q = *self;

        // Ensure w is non-negative to get angle in [0, PI]
        if q.w < T::zero() {
            q = -q;
        }

        // If quaternion is close to identity, angle is zero.
        if q.w > T::one() - T::epsilon() {
            return ([T::one(), T::zero(), T::zero()], T::zero());
        }

        let angle = two * q.w.acos();
        let s = (T::one() - q.w * q.w).sqrt();

        // s is guaranteed to be non-trivial here due to the check above.
        let inv_s = T::one() / s;
        ([q.x * inv_s, q.y * inv_s, q.z * inv_s], angle)
    }

    /// Converts the quaternion to a 3x3 rotation matrix.
    ///
    /// The resulting matrix can be used to rotate 3D vectors.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use std::f64::consts::FRAC_PI_2;
    ///
    /// // 90 degrees around the X-axis
    /// let q = Quaternion::from_axis_angle([1.0, 0.0, 0.0], FRAC_PI_2);
    /// let mat = q.to_rotation_matrix();
    ///
    /// // Expected rotation matrix for 90 degrees around X-axis
    /// // [ 1,  0,  0 ]
    /// // [ 0,  0, -1 ]
    /// // [ 0,  1,  0 ]
    /// assert!((mat[0][0] - 1.0).abs() < 1e-9);
    /// assert!((mat[1][1] - 0.0).abs() < 1e-9);
    /// assert!((mat[1][2] - (-1.0)).abs() < 1e-9);
    /// assert!((mat[2][1] - 1.0).abs() < 1e-9);
    /// ```
    pub fn to_rotation_matrix(&self) -> Matrix3<T> {
        let two = T::one() + T::one();
        let x2 = self.x * two;
        let y2 = self.y * two;
        let z2 = self.z * two;

        let xx = self.x * x2;
        let xy = self.x * y2;
        let xz = self.x * z2;
        let yy = self.y * y2;
        let yz = self.y * z2;
        let zz = self.z * z2;
        let wx = self.w * x2;
        let wy = self.w * y2;
        let wz = self.w * z2;

        [
            [T::one() - (yy + zz), xy - wz, xz + wy],
            [xy + wz, T::one() - (xx + zz), yz - wx],
            [xz - wy, yz + wx, T::one() - (xx + yy)],
        ]
    }

    /// Performs spherical linear interpolation (SLERP) between two quaternions.
    ///
    /// SLERP interpolates along the shortest arc on the unit sphere between two quaternions.
    /// The parameter `t` is typically in the range `[0, 1]`.
    ///
    /// # Arguments
    ///
    /// * `other` - The target quaternion for interpolation.
    /// * `t` - The interpolation parameter, where `t=0` returns `self` and `t=1` returns `other`.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use std::f64::consts::FRAC_PI_2;
    ///
    /// let q1 = Quaternion::<f64>::identity();
    /// let q2 = Quaternion::from_axis_angle([1.0, 0.0, 0.0], FRAC_PI_2);
    ///
    /// // Interpolate halfway between q1 and q2
    /// let slerp_q = q1.slerp(&q2, 0.5);
    /// let expected_q = Quaternion::from_axis_angle([1.0, 0.0, 0.0], FRAC_PI_2 / 2.0);
    ///
    /// assert!((slerp_q.w - expected_q.w).abs() < 1e-9);
    /// assert!((slerp_q.x - expected_q.x).abs() < 1e-9);
    /// assert!((slerp_q.y - expected_q.y).abs() < 1e-9);
    /// assert!((slerp_q.z - expected_q.z).abs() < 1e-9);
    /// ```
    pub fn slerp(&self, other: &Self, t: T) -> Self {
        let q1 = *self;
        let mut q2 = *other;

        let mut dot = q1.dot(&q2);

        // We can negate one of the quaternions to take the short way.
        if dot < T::zero() {
            q2 = -q2;
            dot = -dot;
        }

        // If the quaternions are very close, use linear interpolation to avoid division by zero.
        if dot > T::one() - T::epsilon() {
            return (q1 * (T::one() - t) + q2 * t).normalize();
        }
        // Clamp dot to avoid NaN from acos due to floating point inaccuracies
        dot = dot.clamp(-T::one(), T::one());
        let theta = dot.acos();
        let sin_theta = theta.sin();

        let s1 = ((T::one() - t) * theta).sin() / sin_theta;
        let s2 = (t * theta).sin() / sin_theta;

        (q1 * s1) + (q2 * s2)
    }

    pub fn sin(self) -> Self {
        let v_norm = (self.x * self.x + self.y * self.y + self.z * self.z).sqrt();
        if v_norm.is_zero() {
            return Self::new(self.w.sin(), T::zero(), T::zero(), T::zero());
        }

        let scalar_part = self.w.sin() * v_norm.cosh();
        let vector_scale = self.w.cos() * v_norm.sinh() / v_norm;

        Self::new(
            scalar_part,
            self.x * vector_scale,
            self.y * vector_scale,
            self.z * vector_scale,
        )
    }

    pub fn cos(self) -> Self {
        let v_norm = (self.x * self.x + self.y * self.y + self.z * self.z).sqrt();
        if v_norm.is_zero() {
            return Self::new(self.w.cos(), T::zero(), T::zero(), T::zero());
        }

        let scalar_part = self.w.cos() * v_norm.cosh();
        let vector_scale = -self.w.sin() * v_norm.sinh() / v_norm;

        Self::new(
            scalar_part,
            self.x * vector_scale,
            self.y * vector_scale,
            self.z * vector_scale,
        )
    }

    pub fn tan(self) -> Self {
        self.sin() / self.cos()
    }

    pub fn sinh(self) -> Self {
        let v_norm = (self.x * self.x + self.y * self.y + self.z * self.z).sqrt();
        if v_norm.is_zero() {
            return Self::new(self.w.sinh(), T::zero(), T::zero(), T::zero());
        }

        let scalar_part = self.w.sinh() * v_norm.cos();
        let vector_scale = self.w.cosh() * v_norm.sin() / v_norm;

        Self::new(
            scalar_part,
            self.x * vector_scale,
            self.y * vector_scale,
            self.z * vector_scale,
        )
    }

    pub fn cosh(self) -> Self {
        let v_norm = (self.x * self.x + self.y * self.y + self.z * self.z).sqrt();
        if v_norm.is_zero() {
            return Self::new(self.w.cosh(), T::zero(), T::zero(), T::zero());
        }

        let scalar_part = self.w.cosh() * v_norm.cos();
        let vector_scale = self.w.sinh() * v_norm.sin() / v_norm;

        Self::new(
            scalar_part,
            self.x * vector_scale,
            self.y * vector_scale,
            self.z * vector_scale,
        )
    }

    pub fn tanh(self) -> Self {
        self.sinh() / self.cosh()
    }

    pub fn acos(self) -> Self {
        let v_norm = (self.x * self.x + self.y * self.y + self.z * self.z).sqrt();

        if v_norm.is_zero() {
            return Self::new(self.w.acos(), T::zero(), T::zero(), T::zero());
        }

        let angle = self.w.acos();
        let scale = -angle / v_norm;

        Self::new(T::zero(), self.x * scale, self.y * scale, self.z * scale)
    }

    pub fn ln(self) -> Self {
        let q_norm = self.norm();
        let v_norm = (self.x * self.x + self.y * self.y + self.z * self.z).sqrt();

        if v_norm.is_zero() {
            if self.w >= T::zero() {
                return Self::new(self.w.ln(), T::zero(), T::zero(), T::zero());
            } else {
                return Self::new((-self.w).ln(), T::pi(), T::zero(), T::zero());
            }
        }

        let scalar_part = q_norm.ln();
        let angle = (self.w / q_norm).acos();
        let vector_scale = angle / v_norm;

        Self::new(
            scalar_part,
            self.x * vector_scale,
            self.y * vector_scale,
            self.z * vector_scale,
        )
    }

    pub fn exp(self) -> Self {
        let w_exp = self.w.exp();
        let v_norm = (self.x * self.x + self.y * self.y + self.z * self.z).sqrt();

        if v_norm.is_zero() {
            return Self::new(w_exp, T::zero(), T::zero(), T::zero());
        }

        let scalar_part = w_exp * v_norm.cos();
        let vector_scale = w_exp * v_norm.sin() / v_norm;

        Self::new(
            scalar_part,
            self.x * vector_scale,
            self.y * vector_scale,
            self.z * vector_scale,
        )
    }

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

    pub fn powf(&self, n: T) -> Self {
        (self.ln() * n).exp()
    }

    pub fn powc(&self, p: Self) -> Self {
        (p * self.ln()).exp()
    }
}
