/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Comparison operations for `DoubleFloat`.

use crate::float_106::Float106;
use core::cmp::Ordering;

// =============================================================================
// Equality
// =============================================================================

impl PartialEq for Float106 {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        // Since DoubleFloat maintains the invariant |lo| <= 0.5 * ulp(hi),
        // the representation is unique (except for zeros/NaNs).
        self.hi == other.hi && self.lo == other.lo
    }
}

impl PartialEq<f64> for Float106 {
    #[inline]
    fn eq(&self, other: &f64) -> bool {
        self.hi == *other && self.lo == 0.0
    }
}

impl PartialEq<Float106> for f64 {
    #[inline]
    fn eq(&self, other: &Float106) -> bool {
        *self == other.hi && other.lo == 0.0
    }
}

// =============================================================================
// Ordering
// =============================================================================

impl PartialOrd for Float106 {
    #[inline]
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        // Lexicographical comparison: hi component dominates
        match self.hi.partial_cmp(&other.hi) {
            Some(Ordering::Equal) => self.lo.partial_cmp(&other.lo),
            ord => ord,
        }
    }

    #[inline]
    fn lt(&self, other: &Self) -> bool {
        self.hi < other.hi || (self.hi == other.hi && self.lo < other.lo)
    }

    #[inline]
    fn le(&self, other: &Self) -> bool {
        self.hi < other.hi || (self.hi == other.hi && self.lo <= other.lo)
    }

    #[inline]
    fn gt(&self, other: &Self) -> bool {
        self.hi > other.hi || (self.hi == other.hi && self.lo > other.lo)
    }

    #[inline]
    fn ge(&self, other: &Self) -> bool {
        self.hi > other.hi || (self.hi == other.hi && self.lo >= other.lo)
    }
}

impl PartialOrd<f64> for Float106 {
    #[inline]
    fn partial_cmp(&self, other: &f64) -> Option<Ordering> {
        self.partial_cmp(&Self::from_f64(*other))
    }
}

impl PartialOrd<Float106> for f64 {
    #[inline]
    fn partial_cmp(&self, other: &Float106) -> Option<Ordering> {
        Float106::from_f64(*self).partial_cmp(other)
    }
}
