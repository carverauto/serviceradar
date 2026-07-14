/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::RealField;
use crate::complex::octonion_number::Octonion;
use core::fmt::Debug;

/// Implements the `Debug` trait for `Octonion`.
///
/// This allows `Octonion` instances to be formatted using the `{:?}` debug formatter.
/// It provides a detailed, structured representation of all eight components of the octonion.
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
/// let o = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
/// // This will print:
/// // Octonion {
/// //     s: 1.0,
/// //     e1: 2.0,
/// //     e2: 3.0,
/// //     e3: 4.0,
/// //     e4: 5.0,
/// //     e5: 6.0,
/// //     e6: 7.0,
/// //     e7: 8.0,
/// // }
/// println!("{:?}", o);
/// ```
impl<F: RealField + Debug> Debug for Octonion<F> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("Octonion")
            .field("s", &self.s)
            .field("e1", &self.e1)
            .field("e2", &self.e2)
            .field("e3", &self.e3)
            .field("e4", &self.e4)
            .field("e5", &self.e5)
            .field("e6", &self.e6)
            .field("e7", &self.e7)
            .finish()
    }
}
