/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Float106;

impl Float106 {
    /// Returns `true` if this value is NaN.
    #[inline]
    pub fn is_nan(self) -> bool {
        self.hi.is_nan()
    }

    /// Returns `true` if this value is infinite.
    #[inline]
    pub fn is_infinite(self) -> bool {
        self.hi.is_infinite()
    }

    /// Returns `true` if this value is finite.
    #[inline]
    pub fn is_finite(self) -> bool {
        self.hi.is_finite()
    }

    /// Returns `true` if this value is positive.
    #[inline]
    pub fn is_sign_positive(self) -> bool {
        self.hi.is_sign_positive()
    }

    /// Returns `true` if this value is negative.
    #[inline]
    pub fn is_sign_negative(self) -> bool {
        self.hi.is_sign_negative()
    }
}
