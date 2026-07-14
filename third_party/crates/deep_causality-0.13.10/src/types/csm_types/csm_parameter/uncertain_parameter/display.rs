/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::UncertainParameter;
use std::fmt;

impl fmt::Display for UncertainParameter {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "UncertainParameter {{ threshold: {}, confidence: {}, epsilon: {}, max_samples: {} }}",
            self.threshold, self.confidence, self.epsilon, self.max_samples
        )
    }
}
