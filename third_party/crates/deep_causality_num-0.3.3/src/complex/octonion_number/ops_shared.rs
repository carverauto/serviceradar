/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{DivisionAlgebra, Octonion, RealField};

impl<T> Octonion<T>
where
    T: RealField,
{
    pub(crate) fn _norm_sqr_impl(&self) -> T {
        self.s * self.s
            + self.e1 * self.e1
            + self.e2 * self.e2
            + self.e3 * self.e3
            + self.e4 * self.e4
            + self.e5 * self.e5
            + self.e6 * self.e6
            + self.e7 * self.e7
    }

    pub(crate) fn _conjugate_impl(&self) -> Self {
        Self {
            s: self.s,
            e1: -self.e1,
            e2: -self.e2,
            e3: -self.e3,
            e4: -self.e4,
            e5: -self.e5,
            e6: -self.e6,
            e7: -self.e7,
        }
    }

    pub(crate) fn _inverse_impl(&self) -> Self {
        let n_sqr = self.norm_sqr();
        if n_sqr.is_zero() {
            let nan = T::nan();
            Self::new(nan, nan, nan, nan, nan, nan, nan, nan)
        } else {
            self.conjugate() / n_sqr
        }
    }
}
