/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Complex;
use deep_causality_algebra::{Normed, RealField};

/// A complex scalar carries the real modulus `|z|² = re² + im²` and scales component-wise.
impl<T: RealField> Normed for Complex<T> {
    type Real = T;

    #[inline]
    fn modulus_squared(&self) -> T {
        (self.re * self.re) + (self.im * self.im)
    }

    #[inline]
    fn scale_by_real(&self, s: T) -> Self {
        Complex::new(self.re * s, self.im * s)
    }
}
