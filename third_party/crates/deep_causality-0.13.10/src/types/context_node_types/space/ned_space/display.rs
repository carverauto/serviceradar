/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::NedSpace;
use std::fmt;

impl fmt::Display for NedSpace {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "NedSpace(id={}, N={:.4}, E={:.4}, D={:.4})",
            self.id, self.north, self.east, self.down
        )
    }
}
