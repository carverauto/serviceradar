/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ConstOne, One};

impl One for usize {
    #[inline]
    fn one() -> usize {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for usize {
    const ONE: Self = 1;
}

impl One for u8 {
    #[inline]
    fn one() -> u8 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for u8 {
    const ONE: Self = 1;
}

impl One for u16 {
    #[inline]
    fn one() -> u16 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for u16 {
    const ONE: Self = 1;
}

impl One for u32 {
    #[inline]
    fn one() -> u32 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for u32 {
    const ONE: Self = 1;
}

impl One for u64 {
    #[inline]
    fn one() -> u64 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for u64 {
    const ONE: Self = 1;
}

impl One for u128 {
    #[inline]
    fn one() -> u128 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for u128 {
    const ONE: Self = 1;
}

impl One for isize {
    #[inline]
    fn one() -> isize {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for isize {
    const ONE: Self = 1;
}

impl One for i8 {
    #[inline]
    fn one() -> i8 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for i8 {
    const ONE: Self = 1;
}

impl One for i16 {
    #[inline]
    fn one() -> i16 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for i16 {
    const ONE: Self = 1;
}

impl One for i32 {
    #[inline]
    fn one() -> i32 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for i32 {
    const ONE: Self = 1;
}

impl One for i64 {
    #[inline]
    fn one() -> i64 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for i64 {
    const ONE: Self = 1;
}

impl One for i128 {
    #[inline]
    fn one() -> i128 {
        1
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1
    }
}
impl ConstOne for i128 {
    const ONE: Self = 1;
}

impl One for f32 {
    #[inline]
    fn one() -> f32 {
        1.0
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1.0
    }
}
impl ConstOne for f32 {
    const ONE: Self = 1.0;
}

impl One for f64 {
    #[inline]
    fn one() -> f64 {
        1.0
    }
    #[inline]
    fn is_one(&self) -> bool {
        *self == 1.0
    }
}
impl ConstOne for f64 {
    const ONE: Self = 1.0;
}
