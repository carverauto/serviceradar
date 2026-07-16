/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::EcefSpace;
use std::fmt;

impl fmt::Display for EcefSpace {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "EcefSpace(id={}, x={:.4}, y={:.4}, z={:.4})",
            self.id, self.x, self.y, self.z
        )
    }
}
