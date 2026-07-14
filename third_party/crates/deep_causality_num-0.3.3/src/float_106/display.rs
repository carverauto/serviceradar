/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Float106;
use core::fmt;
use core::fmt::{LowerExp, UpperExp};

impl fmt::Display for Float106 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // For display, show the sum as best as f64 can represent
        // In practice, users wanting full precision should use hi/lo directly
        if self.lo == 0.0 {
            write!(f, "{}", self.hi)
        } else {
            write!(f, "{}+{}", self.hi, self.lo)
        }
    }
}

impl LowerExp for Float106 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Use hi component for exponential notation since it carries the magnitude
        LowerExp::fmt(&self.hi, f)
    }
}

impl UpperExp for Float106 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Use hi component for exponential notation since it carries the magnitude
        UpperExp::fmt(&self.hi, f)
    }
}
