/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use std::fmt::{Debug, Formatter};

use crate::Assumption;

impl Debug for Assumption {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Assumption: id: {}, description: {}, assumption_tested: {}, assumption_valid: {}",
            self.id,
            self.description,
            self.assumption_tested.read().unwrap().clone(),
            self.assumption_valid.read().unwrap().clone()
        )
    }
}
