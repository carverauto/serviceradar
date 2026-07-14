/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use core::ops::Neg;

use crate::RealField;
use crate::complex::octonion_number::Octonion;

/// Implements the unary negation operator (`-`) for `Octonion` numbers.
///
/// Negation is performed component-wise:
/// `-(s + e₁i + ... + e₇p) = -s - e₁i - ... - e₇p`
///
/// # Arguments
/// * `self` - The `Octonion` to negate.
///
/// # Returns
/// A new `Octonion` with all its components negated.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let o = Octonion::new(1.0, -2.0, 3.0, -4.0, 5.0, -6.0, 7.0, -8.0);
/// let neg_o = -o;
/// assert_eq!(neg_o.s, -1.0);
/// assert_eq!(neg_o.e1, 2.0);
/// assert_eq!(neg_o.e2, -3.0);
/// // ... and so on for other components
/// ```
impl<F: RealField> Neg for Octonion<F> {
    type Output = Self;
    fn neg(self) -> Self {
        Octonion {
            s: -self.s,
            e1: -self.e1,
            e2: -self.e2,
            e3: -self.e3,
            e4: -self.e4,
            e5: -self.e5,
            e6: -self.e6,
            e7: -self.e7,
        }
    }
}
