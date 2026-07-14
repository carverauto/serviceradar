/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Octonion;
use crate::RealField;

impl<F> Octonion<F>
where
    F: RealField,
{
    /// Computes the norm (magnitude) of the octonion.
    ///
    /// The norm is the square root of the sum of the squares of all its components,
    /// which is `sqrt(norm_sqr())`.
    ///
    /// # Returns
    /// The scalar value `F` representing the norm.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    ///
    /// let o = Octonion::new(3.0, 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// assert_eq!(o.norm(), 5.0); // sqrt(3*3 + 4*4) = sqrt(9 + 16) = sqrt(25) = 5
    /// ```
    pub fn norm(&self) -> F {
        self._norm_sqr_impl().sqrt()
    }

    /// Returns a normalized version of the octonion (a unit octonion).
    ///
    /// A unit octonion has a norm of 1. If the current octonion's norm is zero,
    /// the original octonion is returned to avoid division by zero, meaning
    /// `normalize()` on a zero octonion returns a zero octonion.
    ///
    /// # Returns
    /// A new `Octonion` with a norm of 1, or `self` if its norm is zero.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, Octonion64, Zero};
    ///
    /// let o = Octonion64::new(3.0, 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let unit_o = o.normalize();
    /// assert!((unit_o.norm() - 1.0).abs() < 1e-9);
    /// assert_eq!(unit_o.s, 0.6000000000000001); // 3/5
    /// assert_eq!(unit_o.e1, 0.8); // 4/5
    ///
    /// let zero_o = Octonion::<f64>::zero();
    /// assert_eq!(zero_o.normalize(), zero_o);
    /// ```
    pub fn normalize(&self) -> Self {
        let n = self.norm();
        if n.is_zero() { *self } else { *self / n }
    }

    /// Computes the dot product of `self` with another octonion `other`.
    ///
    /// The dot product is the sum of the products of corresponding components:
    /// `s*other.s + e₁*other.e₁ + e₂*other.e₂ + ... + e₇*other.e₇`.
    ///
    /// # Arguments
    /// * `other` - A reference to another `Octonion` with which to compute the dot product.
    ///
    /// # Returns
    /// The scalar value `F` representing the dot product.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    ///
    /// let o1 = Octonion::new(1.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let o2 = Octonion::new(3.0, 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// assert_eq!(o1.dot(&o2), 1.0 * 3.0 + 2.0 * 4.0); // 3 + 8 = 11
    /// ```
    pub fn dot(&self, other: &Self) -> F {
        self.s * other.s
            + self.e1 * other.e1
            + self.e2 * other.e2
            + self.e3 * other.e3
            + self.e4 * other.e4
            + self.e5 * other.e5
            + self.e6 * other.e6
            + self.e7 * other.e7
    }
}
