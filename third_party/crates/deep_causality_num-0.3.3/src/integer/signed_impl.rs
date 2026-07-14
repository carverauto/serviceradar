/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::SignedInt;

// -----------------------------------------------------------------------------
// i8 Implementation
// -----------------------------------------------------------------------------
impl SignedInt for i8 {
    #[inline]
    fn abs(self) -> Self {
        i8::abs(self)
    }

    #[inline]
    fn signum(self) -> Self {
        i8::signum(self)
    }

    #[inline]
    fn is_negative(self) -> bool {
        i8::is_negative(self)
    }

    #[inline]
    fn is_positive(self) -> bool {
        i8::is_positive(self)
    }

    #[inline]
    fn checked_abs(self) -> Option<Self> {
        i8::checked_abs(self)
    }

    #[inline]
    fn checked_neg(self) -> Option<Self> {
        i8::checked_neg(self)
    }

    #[inline]
    fn saturating_abs(self) -> Self {
        i8::saturating_abs(self)
    }

    #[inline]
    fn wrapping_abs(self) -> Self {
        i8::wrapping_abs(self)
    }

    #[inline]
    fn wrapping_neg(self) -> Self {
        i8::wrapping_neg(self)
    }
}

// -----------------------------------------------------------------------------
// i16 Implementation
// -----------------------------------------------------------------------------
impl SignedInt for i16 {
    #[inline]
    fn abs(self) -> Self {
        i16::abs(self)
    }

    #[inline]
    fn signum(self) -> Self {
        i16::signum(self)
    }

    #[inline]
    fn is_negative(self) -> bool {
        i16::is_negative(self)
    }

    #[inline]
    fn is_positive(self) -> bool {
        i16::is_positive(self)
    }

    #[inline]
    fn checked_abs(self) -> Option<Self> {
        i16::checked_abs(self)
    }

    #[inline]
    fn checked_neg(self) -> Option<Self> {
        i16::checked_neg(self)
    }

    #[inline]
    fn saturating_abs(self) -> Self {
        i16::saturating_abs(self)
    }

    #[inline]
    fn wrapping_abs(self) -> Self {
        i16::wrapping_abs(self)
    }

    #[inline]
    fn wrapping_neg(self) -> Self {
        i16::wrapping_neg(self)
    }
}

// -----------------------------------------------------------------------------
// i32 Implementation
// -----------------------------------------------------------------------------
impl SignedInt for i32 {
    #[inline]
    fn abs(self) -> Self {
        i32::abs(self)
    }

    #[inline]
    fn signum(self) -> Self {
        i32::signum(self)
    }

    #[inline]
    fn is_negative(self) -> bool {
        i32::is_negative(self)
    }

    #[inline]
    fn is_positive(self) -> bool {
        i32::is_positive(self)
    }

    #[inline]
    fn checked_abs(self) -> Option<Self> {
        i32::checked_abs(self)
    }

    #[inline]
    fn checked_neg(self) -> Option<Self> {
        i32::checked_neg(self)
    }

    #[inline]
    fn saturating_abs(self) -> Self {
        i32::saturating_abs(self)
    }

    #[inline]
    fn wrapping_abs(self) -> Self {
        i32::wrapping_abs(self)
    }

    #[inline]
    fn wrapping_neg(self) -> Self {
        i32::wrapping_neg(self)
    }
}

// -----------------------------------------------------------------------------
// i64 Implementation
// -----------------------------------------------------------------------------
impl SignedInt for i64 {
    #[inline]
    fn abs(self) -> Self {
        i64::abs(self)
    }

    #[inline]
    fn signum(self) -> Self {
        i64::signum(self)
    }

    #[inline]
    fn is_negative(self) -> bool {
        i64::is_negative(self)
    }

    #[inline]
    fn is_positive(self) -> bool {
        i64::is_positive(self)
    }

    #[inline]
    fn checked_abs(self) -> Option<Self> {
        i64::checked_abs(self)
    }

    #[inline]
    fn checked_neg(self) -> Option<Self> {
        i64::checked_neg(self)
    }

    #[inline]
    fn saturating_abs(self) -> Self {
        i64::saturating_abs(self)
    }

    #[inline]
    fn wrapping_abs(self) -> Self {
        i64::wrapping_abs(self)
    }

    #[inline]
    fn wrapping_neg(self) -> Self {
        i64::wrapping_neg(self)
    }
}

// -----------------------------------------------------------------------------
// i128 Implementation
// -----------------------------------------------------------------------------
impl SignedInt for i128 {
    #[inline]
    fn abs(self) -> Self {
        i128::abs(self)
    }

    #[inline]
    fn signum(self) -> Self {
        i128::signum(self)
    }

    #[inline]
    fn is_negative(self) -> bool {
        i128::is_negative(self)
    }

    #[inline]
    fn is_positive(self) -> bool {
        i128::is_positive(self)
    }

    #[inline]
    fn checked_abs(self) -> Option<Self> {
        i128::checked_abs(self)
    }

    #[inline]
    fn checked_neg(self) -> Option<Self> {
        i128::checked_neg(self)
    }

    #[inline]
    fn saturating_abs(self) -> Self {
        i128::saturating_abs(self)
    }

    #[inline]
    fn wrapping_abs(self) -> Self {
        i128::wrapping_abs(self)
    }

    #[inline]
    fn wrapping_neg(self) -> Self {
        i128::wrapping_neg(self)
    }
}

// -----------------------------------------------------------------------------
// isize Implementation
// -----------------------------------------------------------------------------
impl SignedInt for isize {
    #[inline]
    fn abs(self) -> Self {
        isize::abs(self)
    }

    #[inline]
    fn signum(self) -> Self {
        isize::signum(self)
    }

    #[inline]
    fn is_negative(self) -> bool {
        isize::is_negative(self)
    }

    #[inline]
    fn is_positive(self) -> bool {
        isize::is_positive(self)
    }

    #[inline]
    fn checked_abs(self) -> Option<Self> {
        isize::checked_abs(self)
    }

    #[inline]
    fn checked_neg(self) -> Option<Self> {
        isize::checked_neg(self)
    }

    #[inline]
    fn saturating_abs(self) -> Self {
        isize::saturating_abs(self)
    }

    #[inline]
    fn wrapping_abs(self) -> Self {
        isize::wrapping_abs(self)
    }

    #[inline]
    fn wrapping_neg(self) -> Self {
        isize::wrapping_neg(self)
    }
}
