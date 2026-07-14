/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Float106;

impl From<f64> for Float106 {
    #[inline]
    fn from(x: f64) -> Self {
        Self::from_f64(x)
    }
}

impl From<f32> for Float106 {
    #[inline]
    fn from(x: f32) -> Self {
        Self::from_f64(x as f64)
    }
}

impl From<i32> for Float106 {
    #[inline]
    fn from(x: i32) -> Self {
        Self::from_f64(x as f64)
    }
}

impl From<i64> for Float106 {
    #[inline]
    fn from(x: i64) -> Self {
        Self::from_f64(x as f64)
    }
}

impl From<u32> for Float106 {
    #[inline]
    fn from(x: u32) -> Self {
        Self::from_f64(x as f64)
    }
}

impl From<u64> for Float106 {
    #[inline]
    fn from(x: u64) -> Self {
        Self::from_f64(x as f64)
    }
}

impl From<Float106> for f64 {
    #[inline]
    fn from(x: Float106) -> Self {
        x.hi
    }
}

impl From<Float106> for f32 {
    #[inline]
    fn from(x: Float106) -> Self {
        x.hi as f32
    }
}
