/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Float106;
use core::fmt;

impl fmt::Debug for Float106 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DoubleFloat")
            .field("hi", &self.hi)
            .field("lo", &self.lo)
            .finish()
    }
}
