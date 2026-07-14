/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::EuclideanSpacetime;
use std::fmt;

impl fmt::Display for EuclideanSpacetime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "EuclideanSpacetime(id={}, x={:.3}, y={:.3}, z={:.3}, t={} {:?})",
            self.id, self.x, self.y, self.z, self.t, self.time_scale
        )
    }
}
