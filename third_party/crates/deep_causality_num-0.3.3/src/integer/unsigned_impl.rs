/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::UnsignedInt;

// -----------------------------------------------------------------------------
// u8 Implementation
// -----------------------------------------------------------------------------
impl UnsignedInt for u8 {
    #[inline]
    fn checked_next_power_of_two(self) -> Option<Self> {
        u8::checked_next_power_of_two(self)
    }

    #[inline]
    fn is_power_of_two(self) -> bool {
        u8::is_power_of_two(self)
    }

    #[inline]
    fn next_power_of_two(self) -> Self {
        u8::next_power_of_two(self)
    }
}

// -----------------------------------------------------------------------------
// u16 Implementation
// -----------------------------------------------------------------------------
impl UnsignedInt for u16 {
    #[inline]
    fn checked_next_power_of_two(self) -> Option<Self> {
        u16::checked_next_power_of_two(self)
    }

    #[inline]
    fn is_power_of_two(self) -> bool {
        u16::is_power_of_two(self)
    }

    #[inline]
    fn next_power_of_two(self) -> Self {
        u16::next_power_of_two(self)
    }
}

// -----------------------------------------------------------------------------
// u32 Implementation
// -----------------------------------------------------------------------------
impl UnsignedInt for u32 {
    #[inline]
    fn checked_next_power_of_two(self) -> Option<Self> {
        u32::checked_next_power_of_two(self)
    }

    #[inline]
    fn is_power_of_two(self) -> bool {
        u32::is_power_of_two(self)
    }

    #[inline]
    fn next_power_of_two(self) -> Self {
        u32::next_power_of_two(self)
    }
}

// -----------------------------------------------------------------------------
// u64 Implementation
// -----------------------------------------------------------------------------
impl UnsignedInt for u64 {
    #[inline]
    fn checked_next_power_of_two(self) -> Option<Self> {
        u64::checked_next_power_of_two(self)
    }

    #[inline]
    fn is_power_of_two(self) -> bool {
        u64::is_power_of_two(self)
    }

    #[inline]
    fn next_power_of_two(self) -> Self {
        u64::next_power_of_two(self)
    }
}

// -----------------------------------------------------------------------------
// u128 Implementation
// -----------------------------------------------------------------------------
impl UnsignedInt for u128 {
    #[inline]
    fn checked_next_power_of_two(self) -> Option<Self> {
        u128::checked_next_power_of_two(self)
    }

    #[inline]
    fn is_power_of_two(self) -> bool {
        u128::is_power_of_two(self)
    }

    #[inline]
    fn next_power_of_two(self) -> Self {
        u128::next_power_of_two(self)
    }
}

// -----------------------------------------------------------------------------
// usize Implementation
// -----------------------------------------------------------------------------
impl UnsignedInt for usize {
    #[inline]
    fn checked_next_power_of_two(self) -> Option<Self> {
        usize::checked_next_power_of_two(self)
    }

    #[inline]
    fn is_power_of_two(self) -> bool {
        usize::is_power_of_two(self)
    }

    #[inline]
    fn next_power_of_two(self) -> Self {
        usize::next_power_of_two(self)
    }
}
