/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::DiscreteTime;
use std::fmt::Display;

impl Display for DiscreteTime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "DiscreteTime: id: {}, tick_scale: {}, tick_unit: {:?}",
            self.id, self.tick_scale, self.tick_unit
        )
    }
}
