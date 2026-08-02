/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Simplex;

use core::fmt::{Display, Formatter};

impl Display for Simplex {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        let vertex_str: Vec<String> = self.vertices.iter().map(|v| v.to_string()).collect();
        write!(f, "Simplex({})", vertex_str.join(", "))
    }
}
