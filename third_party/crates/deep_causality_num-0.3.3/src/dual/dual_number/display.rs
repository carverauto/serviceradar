/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Dual, Real};
use core::fmt::{Display, Formatter, Result};

impl<T: Real + Display> Display for Dual<T> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        write!(f, "{} + {}ε", self.re, self.du)
    }
}
