/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Dual, One, Real, Zero};

impl<T: Real> Zero for Dual<T> {
    #[inline]
    fn zero() -> Self {
        Self::new(T::zero(), T::zero())
    }

    #[inline]
    fn is_zero(&self) -> bool {
        self.re.is_zero() && self.du.is_zero()
    }
}

impl<T: Real> One for Dual<T> {
    #[inline]
    fn one() -> Self {
        Self::new(T::one(), T::zero())
    }

    #[inline]
    fn is_one(&self) -> bool {
        self.re.is_one() && self.du.is_zero()
    }
}
