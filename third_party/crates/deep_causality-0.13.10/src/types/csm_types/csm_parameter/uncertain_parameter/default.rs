/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::UncertainParameter;

impl Default for UncertainParameter {
    fn default() -> Self {
        Self {
            threshold: 0.8,
            confidence: 0.95,
            epsilon: 0.05,
            max_samples: 1000,
        }
    }
}
