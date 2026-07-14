/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::RealField;
use crate::complex::octonion_number::Octonion;
use core::fmt::Display;

/// Implements the `Display` trait for `Octonion`.
///
/// This allows `Octonion` instances to be formatted using the `{}` display formatter.
/// It provides a human-readable algebraic representation of the octonion,
/// e.g., `1 + 2e₁ + 3e₂ + ...`.
///
/// If all components are zero, it displays "0".
///
/// # Arguments
/// * `self` - The `Octonion` instance to format.
/// * `f` - The formatter to write to.
///
/// # Returns
/// A `std::fmt::Result` indicating success or failure of the formatting operation.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let o1 = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
/// println!("{}", o1); // Example output: 1 + 2e₁ + 3e₂ + 4e₃ + 5e₄ + 6e₅ + 7e₆ + 8e₇
///
/// let o2 = Octonion::new(0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// println!("{}", o2); // Example output: -1e₁
///
/// let o3 = Octonion::new(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// println!("{}", o3); // Output: 0
/// ```
impl<F: RealField + Display> Display for Octonion<F> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let mut is_first_term = true;

        if !self.s.is_zero() {
            write!(f, "{}", self.s)?;
            is_first_term = false;
        }

        let components = [
            (self.e1, "e₁"),
            (self.e2, "e₂"),
            (self.e3, "e₃"),
            (self.e4, "e₄"),
            (self.e5, "e₅"),
            (self.e6, "e₆"),
            (self.e7, "e₇"),
        ];

        for (value, symbol) in components.iter() {
            if !value.is_zero() {
                if is_first_term {
                    if value < &F::zero() {
                        write!(f, "-{}{}", value.abs(), symbol)?;
                    } else {
                        write!(f, "{}{}", value.abs(), symbol)?;
                    }
                    is_first_term = false;
                } else if *value < F::zero() {
                    write!(f, " - {}{}", value.abs(), symbol)?;
                } else {
                    write!(f, " + {}{}", value.abs(), symbol)?;
                }
            }
        }

        if is_first_term {
            // Means nothing was printed, so it's a zero octonion
            write!(f, "0")
        } else {
            Ok(())
        }
    }
}
