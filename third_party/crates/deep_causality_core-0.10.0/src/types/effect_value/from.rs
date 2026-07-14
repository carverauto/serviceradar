/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::EffectValue;

impl<T> From<T> for EffectValue<T> {
    fn from(value: T) -> Self {
        Self::Value(value)
    }
}
