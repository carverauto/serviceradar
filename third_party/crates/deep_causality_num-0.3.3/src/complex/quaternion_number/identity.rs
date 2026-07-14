/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Quaternion;
use crate::{ConstOne, ConstZero, One, RealField, Zero};

// Zero
impl<F> Zero for Quaternion<F>
where
    F: RealField,
{
    /// Returns the additive identity quaternion (0 + 0i + 0j + 0k).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::{Quaternion, Zero};
    ///
    /// let q = Quaternion::<f64>::zero();
    /// assert_eq!(q, Quaternion::new(0.0, 0.0, 0.0, 0.0));
    /// ```
    fn zero() -> Self {
        Quaternion::new(F::zero(), F::zero(), F::zero(), F::zero())
    }

    /// Returns `true` if the quaternion is the additive identity (all components are zero).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::{Quaternion, Zero};
    ///
    /// let q1 = Quaternion::new(0.0, 0.0, 0.0, 0.0);
    /// assert!(q1.is_zero());
    ///
    /// let q2 = Quaternion::new(1.0, 0.0, 0.0, 0.0);
    /// assert!(!q2.is_zero());
    /// ```
    fn is_zero(&self) -> bool {
        self.w.is_zero() && self.x.is_zero() && self.y.is_zero() && self.z.is_zero()
    }
}

// ConstZero
impl<F> ConstZero for Quaternion<F>
where
    F: RealField + ConstZero,
{
    const ZERO: Self = Quaternion {
        w: F::ZERO,
        x: F::ZERO,
        y: F::ZERO,
        z: F::ZERO,
    };
}

// One
impl<F> One for Quaternion<F>
where
    F: RealField,
{
    /// Returns the multiplicative identity quaternion (1 + 0i + 0j + 0k).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::{Quaternion, One};
    ///
    /// let q = Quaternion::<f64>::one();
    /// assert_eq!(q, Quaternion::new(1.0, 0.0, 0.0, 0.0));
    /// ```
    fn one() -> Self {
        Quaternion::new(F::one(), F::zero(), F::zero(), F::zero())
    }

    /// Returns `true` if the quaternion is the multiplicative identity (1 + 0i + 0j + 0k).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::{Quaternion, One};
    ///
    /// let q1 = Quaternion::new(1.0, 0.0, 0.0, 0.0);
    /// assert!(q1.is_one());
    ///
    /// let q2 = Quaternion::new(1.0, 1.0, 0.0, 0.0);
    /// assert!(!q2.is_one());
    /// ```
    fn is_one(&self) -> bool {
        self.w.is_one() && self.x.is_zero() && self.y.is_zero() && self.z.is_zero()
    }
}

// ConstOne
impl<F> ConstOne for Quaternion<F>
where
    F: RealField + ConstOne + ConstZero,
{
    const ONE: Self = Quaternion {
        w: F::ONE,
        x: F::ZERO,
        y: F::ZERO,
        z: F::ZERO,
    };
}
