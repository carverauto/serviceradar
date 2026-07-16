/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::NedSpace;

impl NedSpace {
    pub fn north(&self) -> f64 {
        self.north
    }

    pub fn east(&self) -> f64 {
        self.east
    }

    pub fn down(&self) -> f64 {
        self.down
    }
}
