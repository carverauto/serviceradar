/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::UncertainParameter;

impl UncertainParameter {
    pub fn threshold(&self) -> f64 {
        self.threshold
    }

    pub fn confidence(&self) -> f64 {
        self.confidence
    }

    pub fn epsilon(&self) -> f64 {
        self.epsilon
    }

    pub fn max_samples(&self) -> usize {
        self.max_samples
    }
}
