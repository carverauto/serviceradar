/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod default;
mod display;
mod getter;

#[derive(Debug, Clone, PartialEq, PartialOrd)]
pub struct UncertainParameter {
    threshold: f64,
    confidence: f64,
    epsilon: f64,
    max_samples: usize,
}

impl UncertainParameter {
    pub fn new(threshold: f64, confidence: f64, epsilon: f64, max_samples: usize) -> Self {
        Self {
            threshold,
            confidence,
            epsilon,
            max_samples,
        }
    }
}
