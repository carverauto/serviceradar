/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::MinkowskiSpacetime;
use std::fmt;

impl fmt::Display for MinkowskiSpacetime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "MinkowskiSpacetime(id={}, t={:.6}s, x={:.3}, y={:.3}, z={:.3})",
            self.id, self.t, self.x, self.y, self.z
        )
    }
}
