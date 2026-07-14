/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Uncertain;

impl Default for Uncertain<f64> {
    fn default() -> Self {
        Self::point(0.0)
    }
}
