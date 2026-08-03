/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Quaternion, RealField};
use core::fmt::Display;

// Display
impl<F: RealField + Display> Display for Quaternion<F> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "{}", self.w)?;
        write!(
            f,
            " {} {}i",
            if self.x < F::zero() { "-" } else { "+" },
            self.x.abs()
        )?;
        write!(
            f,
            " {} {}j",
            if self.y < F::zero() { "-" } else { "+" },
            self.y.abs()
        )?;
        write!(
            f,
            " {} {}k",
            if self.z < F::zero() { "-" } else { "+" },
            self.z.abs()
        )
    }
}
