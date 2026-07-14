/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::TangentSpacetime;

impl std::fmt::Display for TangentSpacetime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "TangentSpacetime(id={}, t={:.3}s, x={:.2}, y={:.2}, z={:.2}, vx={:.2}, vy={:.2}, vz={:.2})",
            self.id, self.t, self.x, self.y, self.z, self.dx, self.dy, self.dz
        )
    }
}
