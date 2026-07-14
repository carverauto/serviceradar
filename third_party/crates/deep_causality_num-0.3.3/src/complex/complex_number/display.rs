/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Complex, RealField};
use core::fmt::{Display, Formatter};

impl<T: RealField + Display> Display for Complex<T> {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        if self.im >= T::zero() {
            write!(f, "{}+{}i", self.re, self.im)
        } else {
            write!(f, "{}{:.1}i", self.re, self.im)
        }
    }
}
