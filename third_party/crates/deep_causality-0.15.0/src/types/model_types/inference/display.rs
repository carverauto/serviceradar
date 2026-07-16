/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use std::fmt::{Display, Formatter};

use crate::Inference;

impl Display for Inference {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Inference: id: {}, question: {}, observation: {}, threshold: {}, effect: {}",
            self.id, self.question, self.observation, self.threshold, self.effect
        )
    }
}
