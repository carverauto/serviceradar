/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use core::ops::Neg;

use crate::{Quaternion, RealField};

// Neg
impl<F> Neg for Quaternion<F>
where
    F: RealField,
{
    type Output = Self;

    /// Returns the negation of the quaternion.
    ///
    /// For a quaternion `q = w + xi + yj + zk`, its negation is `-w - xi - yj - zk`.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    ///
    /// let q = Quaternion::new(1.0, -2.0, 3.0, -4.0);
    /// let neg_q = -q;
    /// assert_eq!(neg_q, Quaternion::new(-1.0, 2.0, -3.0, 4.0));
    /// ```
    fn neg(self) -> Self {
        Quaternion {
            w: -self.w,
            x: -self.x,
            y: -self.y,
            z: -self.z,
        }
    }
}
