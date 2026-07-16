/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::QuaternionSpace;

impl std::fmt::Display for QuaternionSpace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "QuaternionSpace(id={}, w={:.4}, x={:.4}, y={:.4}, z={:.4})",
            self.id, self.w, self.x, self.y, self.z
        )
    }
}
