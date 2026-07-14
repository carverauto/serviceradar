/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::RealField;
use crate::complex::octonion_number::Octonion;
use crate::num::identity::one::{ConstOne, One};
use crate::num::identity::zero::{ConstZero, Zero};

/// Implements the `Zero` trait for `Octonion`.
impl<F: RealField> Zero for Octonion<F> {
    /// Returns the additive identity octonion (0 + 0e₁ + ... + 0e₇).
    ///
    /// # Returns
    /// The zero `Octonion` instance.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    /// use deep_causality_num::Zero;
    ///
    /// let zero_octonion = Octonion::<f64>::zero();
    /// assert!(zero_octonion.is_zero());
    /// ```
    fn zero() -> Self {
        Octonion::new(
            F::zero(),
            F::zero(),
            F::zero(),
            F::zero(),
            F::zero(),
            F::zero(),
            F::zero(),
            F::zero(),
        )
    }

    /// Checks if the octonion is the additive identity (zero).
    ///
    /// An octonion is considered zero if all its components are zero.
    ///
    /// # Returns
    /// `true` if all components are zero, `false` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    /// use deep_causality_num::Zero;
    ///
    /// let o1 = Octonion::<f64>::zero();
    /// assert!(o1.is_zero());
    ///
    /// let o2 = Octonion::new(1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// assert!(!o2.is_zero());
    /// ```
    fn is_zero(&self) -> bool {
        self.s.is_zero()
            && self.e1.is_zero()
            && self.e2.is_zero()
            && self.e3.is_zero()
            && self.e4.is_zero()
            && self.e5.is_zero()
            && self.e6.is_zero()
            && self.e7.is_zero()
    }
}

/// Implements the `ConstZero` trait for `Octonion`.
///
/// Provides a compile-time constant for the zero octonion.
impl<F: RealField + ConstZero> ConstZero for Octonion<F> {
    /// A constant representing the zero octonion.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    /// use deep_causality_num::{ConstZero, Zero};
    ///
    /// let zero_octonion = Octonion::<f64>::ZERO;
    /// assert!(zero_octonion.is_zero());
    /// ```
    const ZERO: Self = Octonion {
        s: F::ZERO,
        e1: F::ZERO,
        e2: F::ZERO,
        e3: F::ZERO,
        e4: F::ZERO,
        e5: F::ZERO,
        e6: F::ZERO,
        e7: F::ZERO,
    };
}

/// Implements the `One` trait for `Octonion`.
impl<F: RealField> One for Octonion<F> {
    /// Returns the multiplicative identity octonion (1 + 0e₁ + ... + 0e₇).
    ///
    /// # Returns
    /// The identity `Octonion` instance.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    /// use deep_causality_num::One;
    ///
    /// let one_octonion = Octonion::<f64>::one();
    /// assert!(one_octonion.is_one());
    /// ```
    fn one() -> Self {
        Octonion::new(
            F::one(),
            F::zero(),
            F::zero(),
            F::zero(),
            F::zero(),
            F::zero(),
            F::zero(),
            F::zero(),
        )
    }

    /// Checks if the octonion is the multiplicative identity (one).
    ///
    /// An octonion is considered one if its scalar part is 1 and all imaginary parts are 0.
    ///
    /// # Returns
    /// `true` if the octonion is the multiplicative identity, `false` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    /// use deep_causality_num::{One, Zero};
    ///
    /// let o1 = Octonion::<f64>::one();
    /// assert!(o1.is_one());
    ///
    /// let o2 = Octonion::new(1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// assert!(!o2.is_one());
    ///
    /// let o3 = Octonion::<f64>::zero();
    /// assert!(!o3.is_one());
    /// ```
    fn is_one(&self) -> bool {
        self.s.is_one()
            && self.e1.is_zero()
            && self.e2.is_zero()
            && self.e3.is_zero()
            && self.e4.is_zero()
            && self.e5.is_zero()
            && self.e6.is_zero()
            && self.e7.is_zero()
    }
}

/// Implements the `ConstOne` trait for `Octonion`.
///
/// Provides a compile-time constant for the identity octonion.
impl<F: RealField + ConstOne + ConstZero> ConstOne for Octonion<F> {
    /// A constant representing the identity octonion.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    /// use deep_causality_num::{ConstOne, One};
    ///
    /// let one_octonion = Octonion::<f64>::ONE;
    /// assert!(one_octonion.is_one());
    /// ```
    const ONE: Self = Octonion {
        s: F::ONE,
        e1: F::ZERO,
        e2: F::ZERO,
        e3: F::ZERO,
        e4: F::ZERO,
        e5: F::ZERO,
        e6: F::ZERO,
        e7: F::ZERO,
    };
}
