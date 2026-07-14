/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Uncertain;

impl Default for Uncertain<bool> {
    fn default() -> Self {
        Self::point(true)
    }
}
