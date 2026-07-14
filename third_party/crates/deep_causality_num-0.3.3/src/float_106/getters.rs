/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Float106;

impl Float106 {
    /// Returns the high-order component.
    #[inline(always)]
    pub const fn hi(self) -> f64 {
        self.hi
    }

    /// Returns the low-order component.
    #[inline(always)]
    pub const fn lo(self) -> f64 {
        self.lo
    }

    /// Converts to `f64`, discarding the low component.
    #[inline]
    pub const fn to_f64(self) -> f64 {
        self.hi
    }
}
