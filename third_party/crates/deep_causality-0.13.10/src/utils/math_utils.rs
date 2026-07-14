/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::iter::Sum;
use std::ops::Add;

use crate::NumericalValue;

pub const ZERO: NumericalValue = 0.0;
pub const MINUS_ONE: NumericalValue = -1.0;

/// returns the absolute value of a numerical value
pub fn abs_num(val: NumericalValue) -> NumericalValue {
    if val > ZERO { val } else { MINUS_ONE * val }
}

/// Returns the sum of all elements in an iterable.
pub fn sum<I, S>(iterable: I) -> S
where
    I: IntoIterator,
    S: Sum<I::Item>,
    I::Item: Add<I::Item, Output = S>,
{
    iterable.into_iter().sum()
}
