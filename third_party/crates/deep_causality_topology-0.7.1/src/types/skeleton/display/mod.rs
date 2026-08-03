/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Skeleton;
use core::fmt::{Display, Formatter};

impl Display for Skeleton {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        write!(
            f,
            "Skeleton(Dim: {}, Num Simplices: {})",
            self.dim,
            self.simplices.len()
        )
    }
}
