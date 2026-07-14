/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Quaternion, RealField};

impl<T: RealField> Quaternion<T> {
    pub(crate) fn _conjugate_impl(&self) -> Self {
        Quaternion {
            w: self.w,
            x: -self.x,
            y: -self.y,
            z: -self.z,
        }
    }

    pub(crate) fn _norm_sqr_impl(&self) -> T {
        self.w * self.w + self.x * self.x + self.y * self.y + self.z * self.z
    }

    pub(crate) fn _inverse_impl(&self) -> Self {
        let n_sqr = self._norm_sqr_impl();
        if n_sqr.is_zero() {
            Quaternion::new(T::nan(), T::nan(), T::nan(), T::nan())
        } else {
            self._conjugate_impl() / n_sqr
        }
    }
}
