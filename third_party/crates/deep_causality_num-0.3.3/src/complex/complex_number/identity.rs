/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Complex, ConstOne, ConstZero, One, RealField, Zero};

// Implement Zero trait
impl<T> Zero for Complex<T>
where
    T: RealField,
{
    #[inline]
    fn zero() -> Self {
        Self::new(T::zero(), T::zero())
    }

    #[inline]
    fn is_zero(&self) -> bool {
        self.re.is_zero() && self.im.is_zero()
    }
}

impl<T> ConstZero for Complex<T>
where
    T: RealField + ConstZero,
{
    const ZERO: Self = Self {
        re: T::ZERO,
        im: T::ZERO,
    };
}

// Implement One trait
impl<T> One for Complex<T>
where
    T: RealField,
{
    #[inline]
    fn one() -> Self {
        Self::new(T::one(), T::zero())
    }

    #[inline]
    fn is_one(&self) -> bool {
        self.re.is_one() && self.im.is_zero()
    }
}

impl<T> ConstOne for Complex<T>
where
    T: RealField + ConstOne + ConstZero,
{
    const ONE: Self = Self {
        re: T::ONE,
        im: T::ZERO,
    };
}
